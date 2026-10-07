// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Git for the git chip: the current branch of a folder (read from
//! .git/HEAD, no git process), and git commands run in the background for
//! the chip's expanded peek (list the local branches, switch to one).

const std = @import("std");
const c = @import("../c.zig").c;
const Process = @import("Process.zig");

/// Current branch of the repo containing `dir`, read from .git/HEAD (no git
/// process). Detached HEAD gives the short commit hash. Empty if not in a repo.
pub fn branch(dir_in: []const u8, out: []u8) []const u8 {
    var dir = dir_in;
    var path_buf: [4200]u8 = undefined;
    var head_buf: [512]u8 = undefined;
    while (dir.len > 0) {
        // Normal repo: <dir>/.git/HEAD
        if (readSmall(std.fmt.bufPrintZ(&path_buf, "{s}/.git/HEAD", .{dir}) catch return "", &head_buf)) |head|
            return parseHead(head, out);
        // Worktree / submodule: <dir>/.git is a file "gitdir: <path>"
        if (readSmall(std.fmt.bufPrintZ(&path_buf, "{s}/.git", .{dir}) catch return "", &head_buf)) |file| {
            const prefix = "gitdir: ";
            if (std.mem.startsWith(u8, file, prefix)) {
                const gd = std.mem.trim(u8, file[prefix.len..], " \r\n");
                var gd_buf: [4200]u8 = undefined;
                const head_path = (if (gd.len > 0 and gd[0] == '/')
                    std.fmt.bufPrintZ(&gd_buf, "{s}/HEAD", .{gd})
                else
                    std.fmt.bufPrintZ(&gd_buf, "{s}/{s}/HEAD", .{ dir, gd })) catch return "";
                var hb: [512]u8 = undefined;
                if (readSmall(head_path, &hb)) |head| return parseHead(head, out);
            }
        }
        if (std.mem.eql(u8, dir, "/")) break;
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return "";
}

fn parseHead(head_in: []const u8, out: []u8) []const u8 {
    const head = std.mem.trim(u8, head_in, " \r\n");
    const ref = "ref: refs/heads/";
    const name = if (std.mem.startsWith(u8, head, ref))
        head[ref.len..]
    else if (std.mem.startsWith(u8, head, "ref: "))
        head["ref: ".len..]
    else
        head[0..@min(head.len, 7)]; // detached: short hash
    const n = @min(name.len, out.len);
    @memcpy(out[0..n], name[0..n]);
    return out[0..n];
}

/// Read up to buf.len bytes of a regular file; null if it can't be read
/// (missing, or a directory).
fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fp = c.fopen(path.ptr, "r") orelse return null;
    defer _ = c.fclose(fp);
    const n = c.fread(buf.ptr, 1, buf.len, fp);
    if (n == 0) return null;
    return buf[0..n];
}

/// A git command running in the background in a folder, on a PTY like any
/// job (so it never blocks the UI); polled with `tick` until it is done.
/// Its output (stdout and stderr together) is kept for the caller.
pub const Run = struct {
    proc: Process,
    out: std.ArrayList(u8) = .empty,
    started_ms: u64,
    done: bool = false,
    code: i32 = 0,

    const timeout_ms = 30_000;
    const max_output = 1 << 20;

    /// `git <args>` in `dir`. No colors, no pager, never asks for input.
    pub fn start(gpa: std.mem.Allocator, dir: [:0]const u8, args: []const []const u8) !Run {
        var argv_buf: [16][]const u8 = undefined;
        const pre = [_][]const u8{ "git", "-c", "color.ui=never", "--no-pager" };
        if (pre.len + args.len > argv_buf.len) return error.TooManyArgs;
        @memcpy(argv_buf[0..pre.len], &pre);
        @memcpy(argv_buf[pre.len..][0..args.len], args);
        const env = [_][:0]const u8{ "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true" };
        return .{
            .proc = try Process.spawn(gpa, .{
                .argv = argv_buf[0 .. pre.len + args.len],
                .split_stderr = false,
                .cols = 400,
                .rows = 50,
                .cwd = dir,
                .env = &env,
            }),
            .started_ms = c.SDL_GetTicks(),
        };
    }

    /// Collect output; true once the command is done (exited or timed out).
    pub fn tick(r: *Run, gpa: std.mem.Allocator, reaper: *Process.Reaper) bool {
        if (r.done) return true;
        r.drain(gpa);
        if (r.proc.pollExit()) {
            r.drain(gpa);
            r.code = r.proc.exit_code;
        } else if (c.SDL_GetTicks() - r.started_ms < timeout_ms) {
            return false;
        } else r.code = -1;
        r.proc.terminate(reaper);
        r.done = true;
        return true;
    }

    fn drain(r: *Run, gpa: std.mem.Allocator) void {
        var buf: [8192]u8 = undefined;
        while (r.proc.read(.out, &buf)) |chunk| {
            if (r.out.items.len + chunk.len > max_output) return;
            r.out.appendSlice(gpa, chunk) catch return;
        }
    }

    /// Stop it (if still running) and free the output.
    pub fn deinit(r: *Run, gpa: std.mem.Allocator, reaper: *Process.Reaper) void {
        if (!r.done) r.proc.terminate(reaper);
        r.out.deinit(gpa);
    }
};

/// Arguments that list the local branches, one per line.
pub const list_branches = [_][]const u8{ "for-each-ref", "--format=%(refname:short)", "refs/heads/" };

/// Git's output as plain lines: PTY line ends (\r\n) and escape codes
/// dropped, blank lines skipped. Calls `each` for every line.
pub fn lines(out: []const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), []const u8) void) void {
    var it = std.mem.tokenizeAny(u8, out, "\r\n");
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        if (l.len == 0 or std.mem.indexOfScalar(u8, l, 0x1b) != null) continue;
        each(ctx, l);
    }
}

test "parse git HEAD" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("main", parseHead("ref: refs/heads/main\n", &buf));
    try t.expectEqualStrings("feature/x", parseHead("ref: refs/heads/feature/x\n", &buf));
    try t.expectEqualStrings("f332cad", parseHead("f332cad1234567890abcdef\n", &buf));
}

test "git output lines" {
    const t = std.testing;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(t.allocator);
    const S = struct {
        fn add(l: *std.ArrayList(u8), s: []const u8) void {
            l.appendSlice(t.allocator, s) catch {};
            l.append(t.allocator, '|') catch {};
        }
    };
    lines("main\r\nfeature/x\r\n\r\n\x1b[?2004l\r\n", &got, S.add);
    try t.expectEqualStrings("main|feature/x|", got.items);
}
