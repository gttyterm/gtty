// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Several job windows side by side in the windows area: how many fit, and
//! where each one goes (pure, unit-tested).
//!
//! A job window is usable down to 40 columns × 10 lines (`min` = that size
//! in pixels, title bar and border included). The windows area holds as
//! many of those as fit in columns × rows, at least one.

const std = @import("std");
const Rect = @import("../render/Gfx.zig").Rect;

pub const min_cols = 40;
pub const min_rows = 10;

pub const Size = struct { w: f32, h: f32 };

/// Columns and rows of minimum-size windows that fit in `area` (at least
/// 1 × 1: the active window always shows).
pub fn room(area: Size, min: Size, gap: f32) struct { cols: usize, rows: usize } {
    return .{ .cols = fit(area.w, min.w, gap), .rows = fit(area.h, min.h, gap) };
}

pub fn capacity(area: Size, min: Size, gap: f32) usize {
    const r = room(area, min, gap);
    return r.cols * r.rows;
}

fn fit(len: f32, min: f32, gap: f32) usize {
    if (min <= 0) return 1;
    const n = @floor((len + gap) / (min + gap));
    return if (n < 1) 1 else @intFromFloat(n);
}

/// Place `out.len` windows in `area`, in order (the first is the active
/// window). Picks columns × rows so the most cramped window has the most
/// room relative to `min` (terminal-shaped windows: on a landscape area 5
/// windows get 2 columns × 3 rows); ties go to fewer empty cells. When the
/// grid isn't full, the top row has fewer windows, spread across its width.
pub fn arrange(area: Rect, min: Size, gap: f32, out: []Rect) void {
    const n = out.len;
    if (n == 0) return;
    const r = room(.{ .w = area.w, .h = area.h }, min, gap);
    var best_cols: usize = 1;
    var best_score: f32 = -1;
    var best_empty: usize = std.math.maxInt(usize);
    var cols: usize = 1;
    while (cols <= n) : (cols += 1) {
        const rows = (n + cols - 1) / cols;
        // Only arrangements that fit (always allow the one-window case).
        if (n > 1 and (cols > r.cols or rows > r.rows)) continue;
        const cw = cellLen(area.w, cols, gap);
        const ch = cellLen(area.h, rows, gap);
        const score = @min(cw / @max(min.w, 1), ch / @max(min.h, 1));
        const empty = cols * rows - n;
        if (score > best_score + 1e-4 or (@abs(score - best_score) <= 1e-4 and empty < best_empty)) {
            best_cols = cols;
            best_score = score;
            best_empty = empty;
        }
    }
    // More windows than fit (shouldn't happen: callers keep to capacity):
    // the most square grid anyway.
    if (best_score < 0) best_cols = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n)))))));

    const cols_n = best_cols;
    const rows_n = (n + cols_n - 1) / cols_n;
    const top_n = n - (rows_n - 1) * cols_n;
    const ch = cellLen(area.h, rows_n, gap);
    var k: usize = 0;
    for (0..rows_n) |row| {
        const in_row = if (row == 0) top_n else cols_n;
        const cw = cellLen(area.w, in_row, gap);
        for (0..in_row) |col| {
            out[k] = .{
                .x = @round(area.x + @as(f32, @floatFromInt(col)) * (cw + gap)),
                .y = @round(area.y + @as(f32, @floatFromInt(row)) * (ch + gap)),
                .w = @round(cw),
                .h = @round(ch),
            };
            k += 1;
        }
    }
}

fn cellLen(len: f32, n: usize, gap: f32) f32 {
    const nf: f32 = @floatFromInt(n);
    return @max((len - (nf - 1) * gap) / nf, 1);
}

// A landscape windows area at 1×: about 9 × 18 px text, so a 40 × 10
// window is about 376 × 220 px with its title bar.
const test_area: Rect = .{ .x = 0, .y = 0, .w = 1280, .h = 830 };
const test_min: Size = .{ .w = 376, .h = 220 };

test "capacity: at least one, columns × rows" {
    try std.testing.expectEqual(@as(usize, 9), capacity(.{ .w = 1280, .h = 830 }, test_min, 8));
    try std.testing.expectEqual(@as(usize, 1), capacity(.{ .w = 100, .h = 50 }, test_min, 8));
    try std.testing.expectEqual(@as(usize, 2), capacity(.{ .w = 800, .h = 300 }, test_min, 8));
}

test "4 windows: 2 × 2" {
    var r: [4]Rect = undefined;
    arrange(test_area, test_min, 8, &r);
    try std.testing.expectEqual(r[0].w, r[1].w);
    try std.testing.expectEqual(r[0].y, r[1].y);
    try std.testing.expect(r[2].y > r[0].y);
    try std.testing.expectEqual(r[2].y, r[3].y);
}

test "3 windows: the active one takes the top row, 2 split the bottom" {
    var r: [3]Rect = undefined;
    arrange(test_area, test_min, 8, &r);
    try std.testing.expectEqual(test_area.w, r[0].w);
    try std.testing.expectEqual(r[1].y, r[2].y);
    try std.testing.expect(r[1].y > r[0].y);
    try std.testing.expect(r[1].w < r[0].w);
}

test "5 windows on a landscape area: 2 columns × 3 rows, active on top" {
    var r: [5]Rect = undefined;
    arrange(test_area, test_min, 8, &r);
    try std.testing.expectEqual(test_area.w, r[0].w);
    // Two rows of two under it.
    try std.testing.expectEqual(r[1].y, r[2].y);
    try std.testing.expectEqual(r[3].y, r[4].y);
    try std.testing.expect(r[3].y > r[1].y);
    try std.testing.expectEqual(r[1].w, r[3].w);
}

test "one window fills the area" {
    var r: [1]Rect = undefined;
    arrange(test_area, test_min, 8, &r);
    try std.testing.expectEqual(test_area, r[0]);
}
