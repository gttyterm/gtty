// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! gtty's own connection to the machine of a remote session, next to the
//! user's: their ssh with every option they gave, their environment
//! (SSH_AUTH_SOCK, …) and folder, plus gtty's additions that only affect
//! this connection (remote.linkArgv: never ask for anything, no
//! forwardings, never a ControlMaster). If the user has a ControlMaster
//! running, ssh rides on it; otherwise it logs in by itself with their
//! keys / agent. A host that needs a password can't be reached: the link
//! fails quietly and gtty does without it.
//!
//! On the other side runs a plain `sh` reading commands from a pipe.
//! Each request is one command; its output comes back up to a marker
//! line with the request's id and exit status, so replies are matched to
//! requests (a stale one is simply dropped by whoever asked).
//!
//! `Fetch` copies one file over its own connection: the size first, then
//! the bytes, so progress can be shown; cancel stops it.

const std = @import("std");
const c = @import("../c.zig").c;
const remote = @import("remote.zig");

const RemoteLink = @This();

pub const State = enum { connecting, ready, failed };

/// Who asked: the job window itself (folder / git info) or its file opener.
pub const Owner = enum { window, files };

pub const Reply = struct {
    id: u32,
    owner: Owner,
    /// Exit status 0.
    ok: bool,
    /// The command's output (owned; free with the link's allocator).
    text: []u8,
};

/// What the user's ssh was: its argv, its environment ("NAME=value",
/// each ending in a NUL; empty: gtty's) and its folder.
pub const Spec = struct {
    argv: []const []const u8,
    env: []const u8,
    cwd: []const u8,
};

gpa: std.mem.Allocator,
pid: c_int,
in_fd: c_int,
out_fd: c_int,
state: State = .connecting,
started_ms: u64,
next_id: u32 = 1,
hello_id: u32 = 0,
outbuf: std.ArrayList(u8) = .empty,
rbuf: std.ArrayList(u8) = .empty,
pending: std.ArrayList(struct { id: u32, owner: Owner }) = .empty,
replies: std.ArrayList(Reply) = .empty,

/// Giving up on a login that doesn't finish.
const connect_timeout_ms = 20_000;

pub fn open(gpa: std.mem.Allocator, spec: Spec, now_ms: u64) !*RemoteLink {
    var abuf: [80][]const u8 = undefined;
    const argv = remote.linkArgv(spec.argv, "sh", &abuf) orelse return error.NotRemote;
    const pid, const in_fd, const out_fd = try spawn(gpa, argv, spec);
    const l = try gpa.create(RemoteLink);
    l.* = .{ .gpa = gpa, .pid = pid, .in_fd = in_fd, .out_fd = out_fd, .started_ms = now_ms };
    l.hello_id = l.request(.window, "echo ok") orelse 0;
    return l;
}

/// Run argv with the user's environment and folder, on pipes.
fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, spec: Spec) !struct { c_int, c_int, c_int } {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cargv = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| cargv[i] = (try a.dupeZ(u8, s)).ptr;
    cargv[argv.len] = null;
    var cenv: ?[*]const ?[*:0]const u8 = null;
    if (spec.env.len > 0) {
        var list: std.ArrayList(?[*:0]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, spec.env, "\x00"), 0);
        while (it.next()) |e| if (e.len > 0) try list.append(a, (try a.dupeZ(u8, e)).ptr);
        try list.append(a, null);
        cenv = list.items.ptr;
    }
    const cwd = try a.dupeZ(u8, spec.cwd);
    var in_fd: c_int = -1;
    var out_fd: c_int = -1;
    var pid: c_int = -1;
    if (c.gtty_spawn_pipes(@ptrCast(cargv.ptr), @ptrCast(cenv), cwd.ptr, &in_fd, &out_fd, &pid) != 0) return error.Spawn;
    return .{ pid, in_fd, out_fd };
}

pub fn close(l: *RemoteLink) void {
    c.gtty_close(l.in_fd);
    c.gtty_close(l.out_fd);
    killAndReap(l.pid);
    for (l.replies.items) |r| l.gpa.free(r.text);
    l.replies.deinit(l.gpa);
    l.pending.deinit(l.gpa);
    l.outbuf.deinit(l.gpa);
    l.rbuf.deinit(l.gpa);
    l.gpa.destroy(l);
}

fn killAndReap(pid: c_int) void {
    c.gtty_kill(pid);
    var code: c_int = 0;
    // Killed with SIGKILL: gone at once; reap it (no zombie).
    var tries: usize = 0;
    while (tries < 50 and c.gtty_poll_exit(pid, &code) == 0) : (tries += 1) _ = c.usleep(1000);
}

/// Send a command; its reply comes with the returned id (null: the link
/// failed).
pub fn request(l: *RemoteLink, owner: Owner, cmd: []const u8) ?u32 {
    if (l.state == .failed) return null;
    const id = l.next_id;
    l.next_id += 1;
    // stdin from /dev/null (a command must never read our pipe), errors
    // dropped, then the marker with the id and the status.
    var w: std.Io.Writer.Allocating = .fromArrayList(l.gpa, &l.outbuf);
    w.writer.print("{{\n{s}\n}} </dev/null 2>/dev/null; printf '\\036GTTY {d} %d\\n' $?\n", .{ cmd, id }) catch return null;
    l.outbuf = w.toArrayList();
    l.pending.append(l.gpa, .{ .id = id, .owner = owner }) catch return null;
    l.flush();
    return id;
}

fn flush(l: *RemoteLink) void {
    while (l.outbuf.items.len > 0) {
        const n = c.gtty_write(l.in_fd, l.outbuf.items.ptr, l.outbuf.items.len);
        if (n <= 0) {
            if (n < 0) l.fail();
            return;
        }
        l.outbuf.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
    }
}

fn fail(l: *RemoteLink) void {
    if (l.state == .failed) return;
    l.state = .failed;
    c.gtty_kill(l.pid);
}

/// Each frame: send what waits, read what came. True when something
/// changed (a reply, ready, failed).
pub fn poll(l: *RemoteLink, now_ms: u64) bool {
    if (l.state == .failed) return false;
    const before = l.state;
    const n_before = l.replies.items.len;
    l.flush();
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.gtty_read(l.out_fd, &buf, buf.len);
        if (n == c.GTTY_AGAIN) break;
        if (n <= 0) {
            l.fail(); // the connection ended
            break;
        }
        l.rbuf.appendSlice(l.gpa, buf[0..@intCast(n)]) catch break;
    }
    l.parse();
    if (l.state == .connecting and now_ms -| l.started_ms > connect_timeout_ms) l.fail();
    var code: c_int = 0;
    if (l.state != .failed and c.gtty_poll_exit(l.pid, &code) == 1) l.state = .failed;
    return l.state != before or l.replies.items.len != n_before;
}

/// Cut complete replies off the read buffer.
fn parse(l: *RemoteLink) void {
    const tag = "\x1eGTTY ";
    while (std.mem.indexOf(u8, l.rbuf.items, tag)) |at| {
        const nl = std.mem.indexOfScalarPos(u8, l.rbuf.items, at, '\n') orelse return;
        var it = std.mem.tokenizeScalar(u8, l.rbuf.items[at + tag.len .. nl], ' ');
        const id = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
        const status = std.fmt.parseInt(i32, it.next() orelse "", 10) catch -1;
        const text: []u8 = l.gpa.dupe(u8, l.rbuf.items[0..at]) catch return; // out of memory: try again later
        l.rbuf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
        var owner: Owner = .window;
        for (l.pending.items, 0..) |p, i| if (p.id == id) {
            owner = p.owner;
            _ = l.pending.orderedRemove(i);
            break;
        };
        if (id == l.hello_id) {
            l.gpa.free(text);
            if (status == 0) l.state = .ready;
            continue;
        }
        l.replies.append(l.gpa, .{ .id = id, .owner = owner, .ok = status == 0, .text = text }) catch l.gpa.free(text);
    }
}

/// The oldest reply for `owner` (the caller frees `text` with the link's
/// allocator), or null.
pub fn take(l: *RemoteLink, owner: Owner) ?Reply {
    for (l.replies.items, 0..) |r, i| if (r.owner == owner) return l.replies.orderedRemove(i);
    return null;
}

// ------------------------------------------------------------ copying a file

pub const Fetch = struct {
    pid: c_int,
    out_fd: c_int,
    file: ?*c.FILE,
    /// The local copy (NUL-terminated, owned).
    local: [:0]u8,
    size: ?u64 = null,
    got: u64 = 0,
    head: [32]u8 = undefined,
    head_len: usize = 0,
    state: enum { running, done, failed } = .running,

    /// Start copying remote `path` to `local` (its folder must exist).
    pub fn start(gpa: std.mem.Allocator, spec: Spec, path: []const u8, local: []const u8) !Fetch {
        var cbuf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&cbuf);
        try remote.fetchCommand(&w, path);
        var abuf: [80][]const u8 = undefined;
        const argv = remote.linkArgv(spec.argv, w.buffered(), &abuf) orelse return error.NotRemote;
        const lz = try gpa.dupeZ(u8, local);
        errdefer gpa.free(lz);
        const fp = c.fopen(lz.ptr, "wb") orelse return error.LocalFile;
        errdefer _ = c.fclose(fp);
        const pid, const in_fd, const out_fd = try spawn(gpa, argv, spec);
        c.gtty_close(in_fd);
        return .{ .pid = pid, .out_fd = out_fd, .file = fp, .local = lz };
    }

    /// Read what came. True when something changed.
    pub fn poll(f: *Fetch) bool {
        if (f.state != .running) return false;
        var changed = false;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.gtty_read(f.out_fd, &buf, buf.len);
            if (n == c.GTTY_AGAIN) break;
            if (n <= 0) {
                f.finish();
                return true;
            }
            var data = buf[0..@intCast(n)];
            changed = true;
            // The first line: the size.
            if (f.size == null) {
                const nl = std.mem.indexOfScalar(u8, data, '\n');
                const k1 = if (nl) |k| k + 1 else data.len;
                if (f.head_len + k1 > f.head.len) return f.failNow();
                @memcpy(f.head[f.head_len..][0..k1], data[0..k1]);
                f.head_len += k1;
                data = data[k1..];
                if (nl == null) continue;
                const s = std.mem.trim(u8, f.head[0..f.head_len], " \t\r\n");
                f.size = std.fmt.parseInt(u64, s, 10) catch return f.failNow();
            }
            if (data.len > 0 and c.fwrite(data.ptr, 1, data.len, f.file) != data.len) return f.failNow();
            f.got += data.len;
        }
        return changed;
    }

    fn finish(f: *Fetch) void {
        var code: c_int = -1;
        var tries: usize = 0;
        while (tries < 200 and c.gtty_poll_exit(f.pid, &code) == 0) : (tries += 1) _ = c.usleep(1000);
        const ok = code == 0 and f.size != null and f.got == f.size.?;
        if (c.fclose(f.file) != 0 or !ok) {
            f.file = null;
            _ = f.failNow();
            return;
        }
        f.file = null;
        c.gtty_close(f.out_fd);
        f.out_fd = -1;
        _ = c.chmod(f.local.ptr, 0o444); // read-only: edits don't go back
        f.state = .done;
    }

    fn failNow(f: *Fetch) bool {
        f.stop();
        f.state = .failed;
        return true;
    }

    /// Stop it (if running) and delete the partial copy.
    pub fn stop(f: *Fetch) void {
        if (f.out_fd >= 0) c.gtty_close(f.out_fd);
        f.out_fd = -1;
        killAndReap(f.pid);
        if (f.file) |fp| _ = c.fclose(fp);
        f.file = null;
        if (f.state != .done) _ = c.unlink(f.local.ptr);
    }

    pub fn deinit(f: *Fetch, gpa: std.mem.Allocator) void {
        if (f.state == .running) {
            f.stop();
            f.state = .failed;
        }
        gpa.free(f.local);
    }
};
