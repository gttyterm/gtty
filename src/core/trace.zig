// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Debug trace (`GTTY_TRACE=<file>`): key and text events, window
//! resizes and the bytes gtty sends to each job's terminal, one line each,
//! with a ms timestamp. Read it next to the job's output log
//! (`$TMPDIR/gtty-<pid>/job-<n>.log`) to see what a program got and what
//! it printed back. Off (nothing written) without the variable.

const std = @import("std");
const c = @import("../c.zig").c;

var file: ?*c.FILE = null;

/// Open the trace file named by GTTY_TRACE, if set.
pub fn init() void {
    const path = c.getenv("GTTY_TRACE") orelse return;
    file = c.fopen(path, "w");
}

pub fn on() bool {
    return file != null;
}

/// One line: "<ms> <text>".
pub fn line(comptime fmt: []const u8, args: anytype) void {
    const f = file orelse return;
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d} " ++ fmt ++ "\n", .{c.SDL_GetTicks()} ++ args) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
    _ = c.fflush(f);
}

/// Bytes as readable text: printable ASCII as is, the rest as \xNN.
pub fn bytes(label: []const u8, serial: u32, data: []const u8) void {
    if (file == null) return;
    var buf: [900]u8 = undefined;
    var n: usize = 0;
    for (data) |b| {
        if (n + 4 > buf.len) break;
        if (b >= 0x20 and b < 0x7f and b != '\\') {
            buf[n] = b;
            n += 1;
        } else {
            const e = std.fmt.bufPrint(buf[n..], "\\x{x:0>2}", .{b}) catch break;
            n += e.len;
        }
    }
    line("{s} #{d} {s}", .{ label, serial, buf[0..n] });
}
