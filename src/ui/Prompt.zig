// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The fixed command area at the bottom of the gtty screen:
//! a two-line input editor, with the status bar line underneath it
//! (drawn by StatusBar into `status_r`).

const std = @import("std");
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;

const Prompt = @This();

gpa: std.mem.Allocator,
text: std.ArrayList(u21) = .empty,
cursor: usize = 0,
history: std.ArrayList([]u8) = .empty,
/// Index into history while browsing with Up/Down; null when editing a new line.
hist_pos: ?usize = null,
/// Line being edited before history browsing started.
stash: std.ArrayList(u21) = .empty,

rect: Rect = .{},
input_r: Rect = .{},
status_r: Rect = .{},

pub fn init(gpa: std.mem.Allocator) Prompt {
    return .{ .gpa = gpa };
}

pub fn deinit(p: *Prompt) void {
    p.text.deinit(p.gpa);
    p.stash.deinit(p.gpa);
    for (p.history.items) |h| p.gpa.free(h);
    p.history.deinit(p.gpa);
}

// ------------------------------------------------------------ editing

pub fn insertUtf8(p: *Prompt, s: []const u8) void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n' or cp == '\r') continue;
        p.text.insert(p.gpa, p.cursor, cp) catch return;
        p.cursor += 1;
    }
    p.hist_pos = null;
}

pub fn backspace(p: *Prompt) void {
    if (p.cursor == 0) return;
    p.cursor -= 1;
    _ = p.text.orderedRemove(p.cursor);
}

pub fn delete(p: *Prompt) void {
    if (p.cursor < p.text.items.len) _ = p.text.orderedRemove(p.cursor);
}

pub fn left(p: *Prompt) void {
    p.cursor -|= 1;
}
pub fn right(p: *Prompt) void {
    p.cursor = @min(p.cursor + 1, p.text.items.len);
}
pub fn home(p: *Prompt) void {
    p.cursor = 0;
}
pub fn end(p: *Prompt) void {
    p.cursor = p.text.items.len;
}

pub fn wordLeft(p: *Prompt) void {
    while (p.cursor > 0 and p.text.items[p.cursor - 1] == ' ') p.cursor -= 1;
    while (p.cursor > 0 and p.text.items[p.cursor - 1] != ' ') p.cursor -= 1;
}
pub fn wordRight(p: *Prompt) void {
    const n = p.text.items.len;
    while (p.cursor < n and p.text.items[p.cursor] == ' ') p.cursor += 1;
    while (p.cursor < n and p.text.items[p.cursor] != ' ') p.cursor += 1;
}

pub fn clear(p: *Prompt) void {
    p.text.clearRetainingCapacity();
    p.cursor = 0;
    p.hist_pos = null;
}

pub fn isEmpty(p: *const Prompt) bool {
    return p.text.items.len == 0;
}

/// Take the current line as UTF-8 (caller frees), add it to history and clear.
pub fn take(p: *Prompt) ![]u8 {
    const line = try encode(p.gpa, p.text.items);
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len > 0) {
        const last = if (p.history.items.len > 0) p.history.items[p.history.items.len - 1] else "";
        if (!std.mem.eql(u8, last, line)) p.history.append(p.gpa, try p.gpa.dupe(u8, line)) catch {};
    }
    p.clear();
    return line;
}

pub fn historyPrev(p: *Prompt) void {
    if (p.history.items.len == 0) return;
    if (p.hist_pos) |i| {
        if (i == 0) return;
        p.hist_pos = i - 1;
    } else {
        p.stash.clearRetainingCapacity();
        p.stash.appendSlice(p.gpa, p.text.items) catch {};
        p.hist_pos = p.history.items.len - 1;
    }
    p.load(p.history.items[p.hist_pos.?]);
}

pub fn historyNext(p: *Prompt) void {
    const i = p.hist_pos orelse return;
    if (i + 1 < p.history.items.len) {
        p.hist_pos = i + 1;
        p.load(p.history.items[i + 1]);
    } else {
        p.hist_pos = null;
        p.text.clearRetainingCapacity();
        p.text.appendSlice(p.gpa, p.stash.items) catch {};
        p.cursor = p.text.items.len;
    }
}

fn load(p: *Prompt, s: []const u8) void {
    const keep = p.hist_pos;
    p.clear();
    p.insertUtf8(s);
    p.hist_pos = keep;
}

fn encode(gpa: std.mem.Allocator, cps: []const u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4]u8 = undefined;
    for (cps) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------ layout & draw

/// Height of the dock for a given face (2 input lines + status bar).
pub fn height(f: *const Gfx.Face, status: *const Gfx.Face, ui: f32) f32 {
    return @round(f.cell_h * 2 + status.cell_h + 30 * ui);
}

pub fn layout(p: *Prompt, r: Rect, f: *const Gfx.Face, ui: f32) void {
    p.rect = r;
    const pad = @round(10 * ui);
    p.input_r = .{ .x = r.x + pad, .y = r.y + @round(8 * ui), .w = r.w - 2 * pad, .h = f.cell_h * 2 };
    const sy = p.input_r.y + p.input_r.h + @round(4 * ui);
    p.status_r = .{ .x = r.x + pad, .y = sy, .w = r.w - 2 * pad, .h = r.y + r.h - sy - @round(3 * ui) };
}

pub const DrawInfo = struct {
    /// Shown before the input, e.g. "gtty ›" or "#2 zsh ›".
    label: []const u8,
    label_color: color.Rgb,
    cursor_visible: bool,
    /// Override for the typed text (red while a rejected line flashes).
    text_color: ?color.Rgb = null,
    /// Dim text shown in place of an empty line (what can be typed).
    hint: ?[]const u8 = null,
};

pub fn draw(p: *Prompt, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, ui: f32, info: DrawInfo) void {
    gfx.fill(p.rect, theme.prompt_bg);
    // Divider between the windows area and the dock (2 px at 1x).
    gfx.fill(.{ .x = p.rect.x, .y = p.rect.y, .w = p.rect.w, .h = @max(@round(2 * ui), 2) }, theme.divider);

    // Label, then the text wrapped over two lines.
    const r = p.input_r;
    const lx = gfx.text(f, r.x, r.y, info.label, info.label_color) + f.cell_w;
    const first_cols: usize = @intFromFloat(@max(@floor((r.x + r.w - lx) / f.cell_w), 1));
    const next_cols: usize = @intFromFloat(@max(@floor(r.w / f.cell_w), 1));

    // Scroll so the cursor is always visible within the two lines.
    const cap = first_cols + next_cols;
    const start: usize = if (p.cursor + 1 > cap) p.cursor + 1 - cap else 0;

    var line: usize = 0;
    var col: usize = 0;
    var i = start;
    var cur_x: f32 = lx;
    var cur_y: f32 = r.y;
    while (i <= p.text.items.len) : (i += 1) {
        const width = if (line == 0) first_cols else next_cols;
        if (col >= width) {
            line += 1;
            col = 0;
            if (line >= 2) break;
        }
        const x0 = if (line == 0) lx else r.x;
        const x = x0 + @as(f32, @floatFromInt(col)) * f.cell_w;
        const y = r.y + @as(f32, @floatFromInt(line)) * f.cell_h;
        if (i == p.cursor) {
            cur_x = x;
            cur_y = y;
        }
        if (i == p.text.items.len) break;
        gfx.glyphAt(f, x, y, p.text.items[i], info.text_color orelse theme.prompt_fg);
        col += 1;
    }
    if (p.text.items.len == 0) if (info.hint) |h| {
        gfx.clip(.{ .x = lx, .y = r.y, .w = r.x + r.w - lx, .h = f.cell_h });
        _ = gfx.text(f, lx + f.cell_w, r.y, h, theme.dim);
        gfx.clip(null);
    };
    if (info.cursor_visible) {
        gfx.fill(.{ .x = cur_x, .y = cur_y, .w = @max(@round(f.cell_w * 0.12), 2), .h = f.cell_h }, theme.cursor);
    }
}
