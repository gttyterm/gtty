// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What a mouse action did to the files of a job window's folder, shown on
//! that window long enough to be seen (a drop copies in a few ms). It looks
//! like the title-bar copy's feedback (`JobWindow.drawCopyFlash`): a white
//! flash over the text, then a bubble in its middle (`JobWindow.bubble`)
//! saying what is happening ("↓ copying a.txt into src…", outlined blue);
//! when the work ends, another flash and the result (green done, red
//! failed, blue for a command typed, not run, gray cancelled), shown for
//! `hold_ms`.
//!
//! The window owns it (`JobWindow.file_fx`, drawn in `draw`, cleared in
//! `tick`); App starts it (`App.startFx`) and ends it (`App.finishFx`).
//! Uses: files dropped in from another app (the copy), a file dragged to
//! another job window (the `cp` / `mv` typed), a file dragged out that
//! left the folder (moved).

const std = @import("std");
const Gfx = @import("../render/Gfx.zig");
const color = @import("../core/color.zig");

const FileFx = @This();
const Rect = Gfx.Rect;
const Rgb = color.Rgb;
const Theme = color.Theme;

/// How long the result stays after the work ended.
pub const hold_ms: u64 = 1600;
/// The white flash's fade, and when the bubble shows after it started
/// (the copy feedback's `copy_white_ms`, `copy_bubble_ms`).
const white_ms: u64 = 350;
const bubble_ms: u64 = 150;
/// The working state is shown at least this long, so the two flashes
/// read as two steps.
const min_work_ms: u64 = 400;

pub const State = enum {
    /// Copying: blue.
    working,
    /// Done: green.
    ok,
    /// Done, but nothing changed yet (a command typed, not run): blue.
    info,
    /// Failed: red.
    failed,
    /// Not done (the user said no, or didn't answer): gray.
    cancelled,
};

/// Tells this one from a later one on the same window (App's `finishFx`).
id: u32,
start_ms: u64,
/// When the result shows (0: still working).
done_ms: u64 = 0,
state: State = .working,
/// What it is doing, and the result (shown from `done_ms`).
text: Text = .{},
result: Text = .{},

const Text = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    fn set(t: *Text, s: []const u8) void {
        t.len = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
        // Don't end inside a UTF-8 sequence.
        while (t.len > 0 and t.len < s.len and (t.buf[t.len] & 0xC0) == 0x80) t.len -= 1;
    }

    fn get(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

pub fn init(id: u32, now: u64, text: []const u8) FileFx {
    var f: FileFx = .{ .id = id, .start_ms = now };
    f.text.set(text);
    return f;
}

/// The work ended (`state` ok / info / failed) with `text`.
pub fn finish(f: *FileFx, state: State, text: []const u8, now: u64) void {
    f.state = state;
    f.result.set(text);
    f.done_ms = @max(now, f.start_ms + min_work_ms);
}

/// Nothing left to draw.
pub fn over(f: *const FileFx, now: u64) bool {
    return f.done_ms != 0 and now >= f.done_ms + hold_ms;
}

/// The bubble's text (icon + what happened) in `buf`, and its outline.
pub fn label(f: *const FileFx, t: *const Theme, now: u64, buf: []u8) struct { []const u8, Rgb } {
    const result = f.done_ms != 0 and now >= f.done_ms;
    const state: State = if (result) f.state else .working;
    const icon: []const u8, const col = switch (state) {
        .working => .{ "↓", t.focus },
        .ok => .{ "✓", t.ok },
        .info => .{ "→", t.focus },
        .failed => .{ "✗", t.stderr_accent },
        .cancelled => .{ "–", t.dim },
    };
    const s = if (result) f.result.get() else f.text.get();
    return .{ std.fmt.bufPrint(buf, "{s} {s}", .{ icon, s }) catch s, col };
}

/// The white flash over `area` (the window's text): when it started and
/// when the result came, each fading out over `white_ms`.
pub fn drawFlash(f: *const FileFx, gfx: *Gfx, area: Rect, now: u64) void {
    for ([_]u64{ f.start_ms, f.done_ms }) |from| {
        if (from == 0 or now < from or now - from >= white_ms) continue;
        const left = 1 - @as(f32, @floatFromInt(now - from)) / @as(f32, white_ms);
        gfx.fillAlpha(area, .{ .r = 255, .g = 255, .b = 255 }, @intFromFloat(@round(110 * left)));
    }
}

/// The bubble shows (after the first flash).
pub fn bubbleShown(f: *const FileFx, now: u64) bool {
    return now -| f.start_ms >= bubble_ms;
}
