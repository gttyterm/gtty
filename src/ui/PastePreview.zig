// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The paste history's preview: the right-click menu's Paste ▸ lists the
//! last copies cut to one short line each, so while the mouse is on one of
//! them gtty shows its whole text in a small floating window next to the
//! submenu (App owns it: `paste_preview`).
//!
//!   * A thin top bar with only a close button (×); the text below, wrapped
//!     at the window's width (line breaks kept, tabs as 4 spaces).
//!   * The wheel, ↑ / ↓, PgUp / PgDn, Home / End scroll it.
//!   * Typing searches (any case): every match highlighted, the current one
//!     brighter and scrolled into view; Enter / ↓ in a search: next match,
//!     Shift+Enter: previous. Backspace edits the search; Esc clears it,
//!     then closes the preview.
//!   * App closes it when the mouse is neither on a paste history row nor
//!     on the preview, and swaps it at once for another row's text.

const std = @import("std");
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const wcwidth = @import("../core/wcwidth.zig");
const JobWindow = @import("JobWindow.zig");

const PastePreview = @This();

/// A wrapped line: bytes [a, b) of `text`.
const Line = struct { a: usize, b: usize };

gpa: std.mem.Allocator,
/// The paste history entry shown (its row in the submenu).
index: usize,
/// The text, cleaned for showing (CR LF / CR → LF, tabs → spaces, other
/// control characters dropped).
text: []u8,
lines: std.ArrayList(Line) = .empty,
/// Width in cells the text is wrapped at.
cols: usize = 1,
/// First line shown.
top: usize = 0,
query_buf: [128]u8 = undefined,
query_len: usize = 0,
/// Byte offsets of the matches of the query; `cur`: the current one.
matches: std.ArrayList(usize) = .empty,
cur: usize = 0,

// Layout (pixels), from `layout`.
r: Rect = .{},
bar_r: Rect = .{},
close_r: Rect = .{},
body_r: Rect = .{},
find_r: Rect = .{},
cell_w: f32 = 1,
cell_h: f32 = 1,
over_close: bool = false,

pub const max_cols = 72;
pub const max_rows = 18;
const min_cols = 24;

pub fn open(gpa: std.mem.Allocator, raw: []const u8, index: usize) !PastePreview {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const b = raw[i];
        switch (b) {
            '\r' => {
                try out.append(gpa, '\n');
                if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
            },
            '\t' => try out.appendSlice(gpa, "    "),
            '\n' => try out.append(gpa, '\n'),
            0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {},
            else => try out.append(gpa, b),
        }
    }
    return .{ .gpa = gpa, .index = index, .text = try out.toOwnedSlice(gpa) };
}

pub fn deinit(p: *PastePreview) void {
    p.gpa.free(p.text);
    p.lines.deinit(p.gpa);
    p.matches.deinit(p.gpa);
}

/// Cells of one character.
fn cpWidth(cp: u21) usize {
    return wcwidth.width(cp);
}

/// Wrap the text at `cols` cells (a long word is cut where it hits the edge).
fn wrap(p: *PastePreview, cols: usize) void {
    p.cols = @max(cols, 1);
    p.lines.clearRetainingCapacity();
    var a: usize = 0;
    var w: usize = 0;
    var i: usize = 0;
    while (i < p.text.len) {
        if (p.text[i] == '\n') {
            p.lines.append(p.gpa, .{ .a = a, .b = i }) catch return;
            i += 1;
            a = i;
            w = 0;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(p.text[i]) catch 1;
        const end = @min(i + n, p.text.len);
        const cp = std.unicode.utf8Decode(p.text[i..end]) catch ' ';
        const cw = cpWidth(cp);
        if (w + cw > p.cols and w > 0) {
            p.lines.append(p.gpa, .{ .a = a, .b = i }) catch return;
            a = i;
            w = 0;
        }
        w += cw;
        i = end;
    }
    p.lines.append(p.gpa, .{ .a = a, .b = p.text.len }) catch return;
}

/// The longest line, in cells (for the window's width).
fn longest(p: *const PastePreview) usize {
    var best: usize = 0;
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(p.text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n') {
            best = @max(best, w);
            w = 0;
        } else w += cpWidth(cp);
    }
    return @max(best, w);
}

/// Place the window next to `beside` (the submenu), its top at `row_y`
/// (the row the mouse is on), inside `screen`; wrap the text to fit.
pub fn layout(p: *PastePreview, f: *const Gfx.Face, small: *const Gfx.Face, ui: f32, beside: Rect, row_y: f32, screen: Rect) void {
    p.cell_w = f.cell_w;
    p.cell_h = f.cell_h;
    const pad = @round(8 * ui);
    const bar_h = @round(small.cell_h * 1.25);
    const find_h = @round(small.cell_h * 1.5);
    const cols = std.math.clamp(p.longest(), min_cols, max_cols);
    const w = @min(@as(f32, @floatFromInt(cols)) * f.cell_w + 2 * pad + @round(6 * ui), screen.w);
    const text_cols: usize = @intFromFloat(@max(@floor((w - 2 * pad - @round(6 * ui)) / f.cell_w), 1));
    p.wrap(text_cols);
    const rows = std.math.clamp(p.lines.items.len, 1, max_rows);
    const h = @min(bar_h + @as(f32, @floatFromInt(rows)) * f.cell_h + 2 * pad + find_h, screen.h);
    // Right of the submenu, else left of it; kept on screen.
    var x = beside.x + beside.w;
    if (x + w > screen.x + screen.w) x = beside.x - w;
    x = std.math.clamp(x, screen.x, @max(screen.x + screen.w - w, screen.x));
    const y = std.math.clamp(row_y, screen.y, @max(screen.y + screen.h - h, screen.y));
    p.r = .{ .x = x, .y = y, .w = w, .h = h };
    p.bar_r = .{ .x = x, .y = y, .w = w, .h = bar_h };
    const cs = @round(bar_h * 0.8);
    p.close_r = .{ .x = x + w - cs - @round((bar_h - cs) / 2), .y = y + @round((bar_h - cs) / 2), .w = cs, .h = cs };
    p.body_r = .{ .x = x + pad, .y = y + bar_h + pad, .w = w - 2 * pad, .h = h - bar_h - 2 * pad - find_h };
    p.find_r = .{ .x = x, .y = y + h - find_h, .w = w, .h = find_h };
    p.clampTop();
}

pub fn contains(p: *const PastePreview, x: f32, y: f32) bool {
    return p.r.contains(x, y);
}

fn visibleRows(p: *const PastePreview) usize {
    return @max(@as(usize, @intFromFloat(@floor(p.body_r.h / p.cell_h))), 1);
}

fn clampTop(p: *PastePreview) void {
    const n = p.lines.items.len;
    const vis = p.visibleRows();
    p.top = @min(p.top, n -| vis);
}

pub fn scrollBy(p: *PastePreview, n: isize) void {
    const t: isize = @as(isize, @intCast(p.top)) + n;
    p.top = @intCast(@max(t, 0));
    p.clampTop();
}

/// The mouse wheel over it (`dy` > 0: up).
pub fn wheel(p: *PastePreview, dy: f32) void {
    p.scrollBy(-@as(isize, @intFromFloat(@round(dy * 3))));
}

/// Mouse moved over it: the close button lights up. True when that changed.
pub fn motion(p: *PastePreview, x: f32, y: f32) bool {
    const over = p.close_r.contains(x, y);
    if (over == p.over_close) return false;
    p.over_close = over;
    return true;
}

pub const Action = enum { none, close };

/// A left click on it: the close button closes it; the rest does nothing.
pub fn click(p: *const PastePreview, x: f32, y: f32) Action {
    return if (p.close_r.contains(x, y)) .close else .none;
}

/// Typed text goes to the search.
pub fn typed(p: *PastePreview, s: []const u8) void {
    const n = @min(s.len, p.query_buf.len - p.query_len);
    @memcpy(p.query_buf[p.query_len..][0..n], s[0..n]);
    p.query_len += n;
    p.search();
}

pub const Key = enum { up, down, page_up, page_down, home, end, enter, shift_enter, backspace, escape };

pub fn key(p: *PastePreview, k: Key) Action {
    const searching = p.query_len > 0 and p.matches.items.len > 0;
    switch (k) {
        .up => if (searching) p.step(-1) else p.scrollBy(-1),
        .down => if (searching) p.step(1) else p.scrollBy(1),
        .page_up => p.scrollBy(-@as(isize, @intCast(p.visibleRows() -| 1))),
        .page_down => p.scrollBy(@as(isize, @intCast(p.visibleRows() -| 1))),
        .home => p.top = 0,
        .end => p.scrollBy(@intCast(p.lines.items.len)),
        .enter => p.step(1),
        .shift_enter => p.step(-1),
        .backspace => if (p.query_len > 0) {
            // A whole UTF-8 character.
            var n = p.query_len - 1;
            while (n > 0 and p.query_buf[n] & 0xC0 == 0x80) n -= 1;
            p.query_len = n;
            p.search();
        },
        .escape => {
            if (p.query_len == 0) return .close;
            p.query_len = 0;
            p.search();
        },
    }
    return .none;
}

fn query(p: *const PastePreview) []const u8 {
    return p.query_buf[0..p.query_len];
}

/// Find every match of the query (ASCII letters in any case) and show the
/// first one at or after the top line.
fn search(p: *PastePreview) void {
    p.matches.clearRetainingCapacity();
    p.cur = 0;
    const q = p.query();
    if (q.len == 0 or q.len > p.text.len) return;
    var i: usize = 0;
    while (i + q.len <= p.text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(p.text[i..][0..q.len], q)) {
            p.matches.append(p.gpa, i) catch return;
            i += q.len - 1;
        }
    }
    if (p.matches.items.len == 0) return;
    const from = if (p.top < p.lines.items.len) p.lines.items[p.top].a else 0;
    for (p.matches.items, 0..) |m, k| if (m >= from) {
        p.cur = k;
        break;
    };
    p.reveal();
}

/// The next (`d` = 1) or previous (-1) match, wrapping around.
fn step(p: *PastePreview, d: isize) void {
    const n = p.matches.items.len;
    if (n == 0) return;
    p.cur = @intCast(@mod(@as(isize, @intCast(p.cur)) + d, @as(isize, @intCast(n))));
    p.reveal();
}

/// Scroll so the current match is in view.
fn reveal(p: *PastePreview) void {
    if (p.matches.items.len == 0) return;
    const line = p.lineOf(p.matches.items[p.cur]);
    const vis = p.visibleRows();
    if (line < p.top) p.top = line else if (line >= p.top + vis) p.top = line + 1 - vis;
    p.clampTop();
}

/// The wrapped line holding byte `off`.
fn lineOf(p: *const PastePreview, off: usize) usize {
    for (p.lines.items, 0..) |l, k| if (off < l.b or (off == l.b and k + 1 == p.lines.items.len)) return k;
    return p.lines.items.len -| 1;
}

/// Cells from the start of line `l` to byte `off` (in it).
fn cellsTo(p: *const PastePreview, l: Line, off: usize) usize {
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(p.text[l.a..@min(@max(off, l.a), l.b)]).iterator();
    while (it.nextCodepoint()) |cp| w += cpWidth(cp);
    return w;
}

pub fn draw(p: *const PastePreview, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, small: *Gfx.Face, ui: f32) void {
    const t1 = @max(@round(ui), 1);
    gfx.fill(p.r, theme.bg);
    // The thin top bar: only the close button.
    gfx.fill(p.bar_r, theme.title_bg);
    _ = gfx.text(small, p.bar_r.x + @round(8 * ui), p.bar_r.y + @round((p.bar_r.h - small.cell_h) / 2), "paste history", theme.dim);
    if (p.over_close) JobWindow.closeIcon(gfx, p.close_r, theme, ui) else {
        const m = @round(p.close_r.w * 0.3);
        const lt = @max(@round(1.5 * ui), 1);
        const r = p.close_r;
        gfx.line(r.x + m, r.y + m, r.x + r.w - m, r.y + r.h - m, theme.title_fg, lt);
        gfx.line(r.x + r.w - m, r.y + m, r.x + m, r.y + r.h - m, theme.title_fg, lt);
    }

    // The text, with the matches highlighted.
    gfx.clip(p.body_r);
    const vis = p.visibleRows();
    const q = p.query();
    var k = p.top;
    while (k < p.lines.items.len and k < p.top + vis) : (k += 1) {
        const l = p.lines.items[k];
        const y = p.body_r.y + @as(f32, @floatFromInt(k - p.top)) * p.cell_h;
        if (q.len > 0) for (p.matches.items, 0..) |m, mi| {
            const me = m + q.len;
            if (me <= l.a or m >= l.b) continue;
            const x0 = p.body_r.x + @as(f32, @floatFromInt(p.cellsTo(l, m))) * p.cell_w;
            const x1 = p.body_r.x + @as(f32, @floatFromInt(p.cellsTo(l, @min(me, l.b)))) * p.cell_w;
            gfx.fill(.{ .x = x0, .y = y, .w = @max(x1 - x0, p.cell_w), .h = p.cell_h }, if (mi == p.cur) theme.focus.mix(theme.bg, 0.35) else theme.selection);
        };
        _ = gfx.text(f, p.body_r.x, y, p.text[l.a..l.b], theme.fg);
    }
    gfx.clip(null);

    // A scroll bar when it doesn't all fit.
    const n = p.lines.items.len;
    if (n > vis) {
        const track = p.body_r;
        const th = @max(track.h * @as(f32, @floatFromInt(vis)) / @as(f32, @floatFromInt(n)), 12 * ui);
        const ty = track.y + (track.h - th) * @as(f32, @floatFromInt(p.top)) / @as(f32, @floatFromInt(n - vis));
        gfx.fill(.{ .x = p.r.x + p.r.w - @round(5 * ui), .y = ty, .w = @round(3 * ui), .h = th }, theme.divider);
    }

    // The search row.
    gfx.fill(.{ .x = p.find_r.x, .y = p.find_r.y, .w = p.find_r.w, .h = t1 }, theme.divider);
    const sy = p.find_r.y + @round((p.find_r.h - small.cell_h) / 2);
    const sx = p.find_r.x + @round(8 * ui);
    if (q.len == 0) {
        var buf: [64]u8 = undefined;
        const lines = std.fmt.bufPrint(&buf, "type to search  ·  {d} line{s}", .{ n, if (n == 1) "" else "s" }) catch "type to search";
        _ = gfx.text(small, sx, sy, lines, theme.dim);
    } else {
        const ex = gfx.text(small, sx, sy, "find: ", theme.dim);
        const qx = gfx.text(small, ex, sy, q, theme.prompt_fg);
        var buf: [48]u8 = undefined;
        const res = if (p.matches.items.len == 0)
            "  no match"
        else
            std.fmt.bufPrint(&buf, "  {d}/{d}  (Enter: next)", .{ p.cur + 1, p.matches.items.len }) catch "";
        _ = gfx.text(small, qx, sy, res, if (p.matches.items.len == 0) theme.stderr_accent else theme.dim);
    }
    gfx.outline(p.r, theme.focus.mix(theme.bg, 0.4), t1);
}

test "wrap, search, scroll" {
    const t = std.testing;
    var p = try PastePreview.open(t.allocator, "first line\r\nsecond\tline that is long\nFIRST again", 0);
    defer p.deinit();
    try t.expectEqualStrings("first line\nsecond    line that is long\nFIRST again", p.text);
    p.wrap(12);
    // "second    line that is long" (28 cells) wraps over 3 rows.
    try t.expectEqual(@as(usize, 5), p.lines.items.len);
    p.body_r = .{ .h = 2 };
    p.cell_h = 1;
    p.typed("first");
    try t.expectEqual(@as(usize, 2), p.matches.items.len);
    try t.expectEqual(@as(usize, 0), p.cur);
    _ = p.key(.enter);
    try t.expectEqual(@as(usize, 1), p.cur);
    try t.expectEqual(@as(usize, 4), p.lineOf(p.matches.items[1]));
    try t.expect(p.top + 2 > 4); // scrolled to show it
    try t.expectEqual(Action.none, p.key(.escape)); // clears the search
    try t.expectEqual(@as(usize, 0), p.matches.items.len);
    try t.expectEqual(Action.close, p.key(.escape)); // then closes
}
