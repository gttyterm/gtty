// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A child process attached to pseudo-terminals.
//!
//! stdin and stdout share one PTY (the child's controlling terminal, so
//! Ctrl+C / job control / SIGWINCH work). In split mode stderr gets its own
//! PTY, so gtty can show it in a separate pane while the program still
//! believes it writes to a real terminal.

const std = @import("std");
const c = @import("../c.zig").c;

const Process = @This();

pub const Stream = enum { out, err };

pid: c_int = -1,
out_fd: c_int = -1,
err_fd: c_int = -1,
out_open: bool = false,
err_open: bool = false,
exited: bool = false,
exit_code: i32 = 0,

pub const Options = struct {
    argv: []const []const u8,
    split_stderr: bool = true,
    cols: u16 = 80,
    rows: u16 = 24,
    term: [:0]const u8 = "xterm-256color",
    cwd: ?[:0]const u8 = null,
    /// Extra environment for the child, "NAME=value".
    env: []const [:0]const u8 = &.{},
};

pub fn spawn(gpa: std.mem.Allocator, opts: Options) !Process {
    // Build a NULL-terminated argv of NUL-terminated strings for execvp.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try a.alloc(?[*:0]const u8, opts.argv.len + 1);
    for (opts.argv, 0..) |arg, i| argv[i] = (try a.dupeZ(u8, arg)).ptr;
    argv[opts.argv.len] = null;
    const env = try a.alloc(?[*:0]const u8, opts.env.len + 1);
    for (opts.env, 0..) |e, i| env[i] = e.ptr;
    env[opts.env.len] = null;

    var p: Process = .{};
    const rc = c.gtty_spawn(
        @ptrCast(argv.ptr),
        @intFromBool(opts.split_stderr),
        opts.cols,
        opts.rows,
        opts.term.ptr,
        if (opts.cwd) |d| d.ptr else null,
        @ptrCast(env.ptr),
        &p.out_fd,
        &p.err_fd,
        &p.pid,
    );
    if (rc != 0) return error.SpawnFailed;
    p.out_open = true;
    p.err_open = p.err_fd >= 0;
    return p;
}

pub fn running(p: *const Process) bool {
    return p.pid > 0 and !p.exited;
}

/// Read whatever is available on one stream into `buf`.
/// Returns null when nothing is pending, an empty slice never.
pub fn read(p: *Process, which: Stream, buf: []u8) ?[]u8 {
    const fd = if (which == .out) p.out_fd else p.err_fd;
    const open = if (which == .out) &p.out_open else &p.err_open;
    if (!open.*) return null;
    const n = c.gtty_read(fd, buf.ptr, buf.len);
    if (n == c.GTTY_AGAIN) return null;
    if (n == c.GTTY_EOF) {
        open.* = false;
        return null;
    }
    return buf[0..@intCast(n)];
}

/// Wait up to `ms` for more output (or the end): true when there is some.
pub fn waitOutput(p: *Process, ms: c_int) bool {
    if (!p.out_open) return false;
    return c.gtty_wait_readable(p.out_fd, ms) == 1;
}

/// Send bytes to the child's stdin.
pub fn write(p: *Process, bytes: []const u8) void {
    if (!p.out_open) return;
    var rest = bytes;
    var tries: usize = 0;
    while (rest.len > 0 and tries < 1000) : (tries += 1) {
        const n = c.gtty_write(p.out_fd, rest.ptr, rest.len);
        if (n < 0) return;
        rest = rest[@intCast(n)..];
    }
}

/// Tell the child (and the kernel) about a new grid size. The controlling
/// PTY delivers SIGWINCH; the stderr PTY just gets the same size so that
/// programs which measure stderr line width wrap consistently.
pub fn resize(p: *Process, cols: u16, rows: u16) void {
    _ = c.gtty_resize(p.out_fd, cols, rows);
    if (p.err_fd >= 0) _ = c.gtty_resize(p.err_fd, cols, rows);
}

/// Non-blocking check for exit. Returns true once, when the child has exited.
pub fn pollExit(p: *Process) bool {
    if (p.exited or p.pid <= 0) return false;
    var code: c_int = 0;
    if (c.gtty_poll_exit(p.pid, &code) == 1) {
        p.exited = true;
        p.exit_code = code;
        return true;
    }
    return false;
}

/// Ask the job to stop (SIGHUP, like closing a terminal); keeps the PTY so
/// the window can still show its last output and exit status.
pub fn hangup(p: *Process) void {
    if (p.running()) c.gtty_hangup(p.pid);
}

/// SIGKILL, for a job that ignored the hangup.
pub fn killHard(p: *Process) void {
    if (p.running()) c.gtty_kill(p.pid);
}

/// Hang up and release the PTYs. The process is reaped later by `Reaper`.
pub fn terminate(p: *Process, reaper: *Reaper) void {
    if (p.running()) {
        c.gtty_hangup(p.pid);
        reaper.add(p.pid);
    }
    c.gtty_close(p.out_fd);
    c.gtty_close(p.err_fd);
    p.out_fd = -1;
    p.err_fd = -1;
    p.out_open = false;
    p.err_open = false;
    p.exited = true;
}

/// Collects processes we hung up on, so they don't stay as zombies.
/// Anything still alive a few seconds after SIGHUP gets SIGKILL.
pub const Reaper = struct {
    pending: std.ArrayList(Entry) = .empty,
    gpa: std.mem.Allocator,

    const Entry = struct { pid: c_int, since: u64 };

    pub fn add(r: *Reaper, pid: c_int) void {
        r.pending.append(r.gpa, .{ .pid = pid, .since = c.SDL_GetTicks() }) catch {};
    }

    pub fn tick(r: *Reaper) void {
        var i: usize = 0;
        while (i < r.pending.items.len) {
            const e = r.pending.items[i];
            var code: c_int = 0;
            if (c.gtty_poll_exit(e.pid, &code) == 1) {
                _ = r.pending.swapRemove(i);
                continue;
            }
            if (c.SDL_GetTicks() - e.since > 3000) c.gtty_kill(e.pid);
            i += 1;
        }
    }

    pub fn deinit(r: *Reaper) void {
        for (r.pending.items) |e| c.gtty_kill(e.pid);
        r.pending.deinit(r.gpa);
    }
};
