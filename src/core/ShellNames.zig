// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The command names the user's shell knows besides programs on disk:
//! aliases, functions, builtins and keywords — so `ll` counts as a command
//! even though no `ll` file exists.
//!
//! gtty asks the real shell, with the user's config loaded (`zsh -i -c …`),
//! in the background: the query runs on a PTY like any job and is polled
//! from the main loop (`tick`). Until the answer arrives, `has` is false
//! and oscmd.zig's fixed list of builtins still applies.

const std = @import("std");
const c = @import("../c.zig").c;
const Process = @import("Process.zig");

const ShellNames = @This();

gpa: std.mem.Allocator,
names: std.StringHashMapUnmanaged(void) = .empty,
/// Owns the strings in `names`.
blob: []u8 = &.{},
proc: ?Process = null,
out: std.ArrayList(u8) = .empty,
started_ms: u64 = 0,

const marker = "__GTTY_NAMES__";
const timeout_ms = 15_000;
const max_output = 1 << 20;

pub fn init(gpa: std.mem.Allocator) ShellNames {
    return .{ .gpa = gpa };
}

pub fn deinit(sn: *ShellNames, reaper: *Process.Reaper) void {
    if (sn.proc) |*p| p.terminate(reaper);
    sn.names.deinit(sn.gpa);
    sn.gpa.free(sn.blob);
    sn.out.deinit(sn.gpa);
}

/// The shell is still being asked (at most `timeout_ms`).
pub fn busy(sn: *const ShellNames) bool {
    return sn.proc != null;
}

pub fn has(sn: *const ShellNames, name: []const u8) bool {
    return sn.names.contains(name);
}

/// The query for each shell: print a marker, then one name per line.
fn queryFor(shell_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, shell_name, "zsh"))
        return "print -rl -- " ++ marker ++ " ${(k)aliases} ${(k)functions} ${(k)builtins} ${(k)reswords}";
    if (std.mem.eql(u8, shell_name, "bash"))
        return "echo " ++ marker ++ "; compgen -A alias -A function -A builtin -A keyword";
    if (std.mem.eql(u8, shell_name, "fish"))
        return "echo " ++ marker ++ "; printf '%s\\n' (functions -a -n) (builtin -n) (abbr --list)";
    return null; // other shells: the fixed builtin list only
}

/// Start (or restart) asking `shell` for its names, in the background.
pub fn refresh(sn: *ShellNames, shell: []const u8, reaper: *Process.Reaper) void {
    if (sn.proc) |*p| p.terminate(reaper);
    sn.proc = null;
    sn.out.clearRetainingCapacity();
    const script = queryFor(std.fs.path.basename(shell)) orelse return;
    const argv = [_][]const u8{ shell, "-i", "-c", script };
    sn.proc = Process.spawn(sn.gpa, .{ .argv = &argv, .split_stderr = false, .cols = 200, .rows = 50 }) catch null;
    sn.started_ms = c.SDL_GetTicks();
}

/// Collect the shell's answer; once it has exited, take the new names.
pub fn tick(sn: *ShellNames, reaper: *Process.Reaper) void {
    const p = if (sn.proc) |*pp| pp else return;
    var buf: [16 * 1024]u8 = undefined;
    sn.drain(p, &buf);
    if (p.pollExit()) {
        sn.drain(p, &buf); // whatever was still buffered
        sn.take(sn.out.items) catch {};
    } else if (c.SDL_GetTicks() - sn.started_ms < timeout_ms) return;
    p.terminate(reaper);
    sn.proc = null;
}

fn drain(sn: *ShellNames, p: *Process, buf: []u8) void {
    while (p.read(.out, buf)) |chunk| {
        if (sn.out.items.len + chunk.len > max_output) return;
        sn.out.appendSlice(sn.gpa, chunk) catch return;
    }
}

/// Replace the names with those after the marker line in `output`.
fn take(sn: *ShellNames, output: []const u8) !void {
    const at = std.mem.indexOf(u8, output, marker) orelse return;
    const blob = try sn.gpa.dupe(u8, output[at + marker.len ..]);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    errdefer {
        names.deinit(sn.gpa);
        sn.gpa.free(blob);
    }
    var lines = std.mem.tokenizeAny(u8, blob, "\r\n");
    while (lines.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (!plausibleName(name)) continue;
        try names.put(sn.gpa, name, {});
    }
    sn.names.deinit(sn.gpa);
    sn.gpa.free(sn.blob);
    sn.names = names;
    sn.blob = blob;
}

/// Skip terminal noise the shell's config may print (escape codes, text).
fn plausibleName(s: []const u8) bool {
    if (s.len == 0 or s.len > 200) return false;
    for (s) |ch| if (ch <= ' ' or ch == 0x7f) return false;
    return true;
}

test "parse the shell's answer" {
    const t = std.testing;
    var sn = ShellNames.init(t.allocator);
    defer {
        sn.names.deinit(t.allocator);
        t.allocator.free(sn.blob);
        sn.out.deinit(t.allocator);
    }
    try sn.take("rc noise\r\n" ++ marker ++ "\r\nll\r\ngs\r\n\x1b[?2004l\r\nnvm\r\n");
    try t.expect(sn.has("ll"));
    try t.expect(sn.has("nvm"));
    try t.expect(!sn.has("rc"));
    try t.expect(!sn.has("\x1b[?2004l"));
}
