// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A small pop-up menu: the right-click menu (Copy / Paste), `show`'s
//! app picker (Open with …), and the menus of the drawn menu bar (gtty,
//! Edit; Linux: macOS has them in the system menu bar).
//!
//!   * Opens where the click was (the menu's top-left corner), flipped
//!     left / up to stay on screen.
//!   * A list of rows, each with a label, an optional shortcut or note on
//!     the right, and enabled or dimmed; an optional dim title row on top
//!     that can't be picked. A row can have a ▸ box at its right end
//!     (`Row.sub`): a click there opens a submenu (App's `sub_menu`, next
//!     to the row) instead of picking the row. A row that only opens a
//!     submenu (`Row.hover_sub`: the file menu's Open With ▸) opens it
//!     when the mouse rests on it or clicks it; its ▸ has no box.
//!   * Separators (`Row.sep`): a thin line between groups of rows.
//!   * Closes on a click outside (that click does nothing else; a right
//!     click opens the right-click menu again there), on any key (Esc only
//!     closes), the wheel, or a resize.
//!
//! The right-click menu on an outlined file or folder name (or on a
//! ⌘-click selection of them) is the file actions menu (`files`): Open,
//! Rename, Copy, Cut, Paste, Move to Trash, Delete.
//!
//! App owns at most one Menu, routes the mouse to it and acts on the row
//! picked (by its index); what the menu is for is in `purpose`.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("../core/color.zig");
const Theme = color.Theme;
const c = @import("../c.zig").c;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const ids = @import("ids.zig");

const Menu = @This();

pub const max_rows = 16;

pub const Row = struct {
    label: []const u8,
    /// Shown dim on the right: a shortcut ("⌘C") or a note ("default").
    key: []const u8 = "",
    enabled: bool = true,
    /// A ▸ box at the right end opens a submenu (`sub_on`: it has rows).
    sub: bool = false,
    sub_on: bool = false,
    /// With `sub`: the whole row opens the submenu (hover or click).
    hover_sub: bool = false,
    /// A separator line, not a row: never picked.
    sep: bool = false,
    /// A small picture before the label (an app's icon; owned by App).
    icon: ?*c.SDL_Texture = null,
};

/// A separator line between groups of rows.
pub const separator: Row = .{ .label = "", .enabled = false, .sep = true };

/// The right-click menu acts on a job window (by id) or the prompt.
pub const Target = union(enum) { job: ids.Id, prompt };

/// What the menu is for (App acts on the row picked accordingly).
pub const Purpose = union(enum) {
    /// The right-click menu: rows `edit_copy`, `edit_paste`.
    edit: Target,
    /// `show`'s app picker, or the file menu's Open With ▸ submenu: row
    /// `codes[i]` = k opens the file with App's picker app k
    /// (`open_with_other`: the system's choose-an-app dialog).
    open_with,
    /// A menu of the drawn menu bar: row i picks `codes[i]` (a
    /// gtty_menu.h code, as the system menu bar's rows do).
    bar: Bar,
    /// The right-click menu's Paste ▸ submenu: row i pastes App's paste
    /// history entry i into the target.
    paste_history: Target,
    /// The right-click menu's History ▸ submenu: row i types `cd` to the
    /// window's folder history entry i.
    folder_history: ids.Id,
    /// The right-click menu on a file or folder name (window id): the
    /// file actions (`codes[i]`: App's `file_*` codes; the files are
    /// App's `menu_files`).
    files: ids.Id,
};

/// The app picker's "Other…" row: the system's choose-an-app dialog.
pub const open_with_other = -1;

/// The drawn menu bar's menus, left to right.
pub const Bar = enum { gtty };
pub const bar_titles = [_][]const u8{"gtty"};

/// The right-click menu's rows, as `codes[i]` (a row's place depends on
/// which rows the menu has).
pub const edit_copy = 0;
pub const edit_paste = 1;
/// History ▸ (job windows only): the folders the shell left.
pub const edit_folders = 2;
/// Copy last output / Copy all output (job windows only): the title-bar
/// copy.
pub const edit_output = 3;
/// New Shell: in the folder of the window clicked (the prompt: of the
/// current window).
pub const edit_new_shell = 4;

/// New Shell's key (a new tab in other terminals): ⌘T on macOS,
/// Ctrl+Shift+T elsewhere (as GNOME Terminal; Ctrl+T alone is the job's:
/// transpose characters in the shell).
pub const new_shell_key = if (builtin.os.tag == .macos) "⌘T" else "Ctrl+Shift+T";
/// New Window's key (another gtty): ⌘N on macOS, Ctrl+Shift+N elsewhere
/// (as GNOME Terminal; Ctrl+N alone is the job's: the next history line).
pub const new_window_key = if (builtin.os.tag == .macos) "⌘N" else "Ctrl+Shift+N";

pub const edit_keys: [2][]const u8 = if (builtin.os.tag == .macos)
    .{ "⌘C", "⌘V" }
else
    .{ "Ctrl+Shift+C", "Ctrl+Shift+V" };

purpose: Purpose,
/// Where the click was (the menu's top-left corner if it fits).
at: [2]f32,
/// A dim heading over the rows ("Open notes.txt with"), or empty.
title: []const u8 = "",
rows: [max_rows]Row = undefined,
n: usize = 0,
r: Rect = .{},
title_r: Rect = .{},
row_r: [max_rows]Rect = undefined,
/// The enabled row under the mouse.
over: ?usize = null,
/// The mouse is on that row's ▸ box.
over_arrow: bool = false,
/// The ▸ box of each row with `sub`.
arrow_r: [max_rows]Rect = undefined,
/// `bar` menus: what each row does (gtty_menu.h codes).
codes: [max_rows]i32 = undefined,

/// The right-click menu: Copy / Paste, each enabled or dimmed; Paste's ▸
/// opens the paste history (`history_ok`: there is some, and the target
/// takes a paste). `output`: a row under Copy with this label (job
/// windows: "Copy last output" / "Copy all output"). `folders`: a History ▸
/// row (job windows), enabled when the window has a folder history. Each
/// row's `codes[i]` says which it is (`edit_copy`, …). Paste pastes what
/// was copied last: text, or files on gtty's file clipboard (App decides).
pub fn edit(target: Target, at: [2]f32, copy_ok: bool, output: ?[]const u8, paste_ok: bool, history_ok: bool, folders: ?bool) Menu {
    var m: Menu = .{ .purpose = .{ .edit = target }, .at = at };
    m.addCode(.{ .label = "Copy", .key = edit_keys[0], .enabled = copy_ok }, edit_copy);
    if (output) |label| m.addCode(.{ .label = label }, edit_output);
    m.addCode(.{ .label = "Paste", .key = edit_keys[1], .enabled = paste_ok, .sub = true, .sub_on = history_ok }, edit_paste);
    if (folders) |on| m.addCode(.{ .label = "History", .enabled = on, .sub = true, .sub_on = on }, edit_folders);
    m.addCode(.{ .label = "New Shell", .key = new_shell_key }, edit_new_shell);
    return m;
}

/// Add a row with its code.
pub fn addCode(m: *Menu, row: Row, code: i32) void {
    const n = m.n;
    m.add(row);
    if (m.n > n) m.codes[n] = code;
}

/// A menu of the drawn menu bar under its button at `at`; `codes[i]` is
/// what row i does.
pub fn bar(which: Bar, at: [2]f32, rows: []const Row, codes: []const i32) Menu {
    var m: Menu = .{ .purpose = .{ .bar = which }, .at = at };
    for (rows, codes) |row, code| {
        if (m.n < max_rows) m.codes[m.n] = code;
        m.add(row);
    }
    return m;
}

/// Add a row (ignored once `max_rows` are there).
pub fn add(m: *Menu, row: Row) void {
    if (m.n == max_rows) return;
    m.rows[m.n] = row;
    m.n += 1;
}

fn pad(ui: f32) f32 {
    return @round(10 * ui);
}

fn edge(ui: f32) f32 {
    return @round(4 * ui);
}

/// Size the menu for face `f` and place it at the click, flipped left /
/// up where it would leave `bounds`.
pub fn layout(m: *Menu, f: *const Gfx.Face, ui: f32, bounds: Rect) void {
    const row_h = @round(f.cell_h * 1.6);
    var lw: f32 = Gfx.textWidth(f, m.title);
    var sw: f32 = 0;
    for (m.rows[0..m.n]) |row| {
        lw = @max(lw, Gfx.textWidth(f, row.label));
        sw = @max(sw, Gfx.textWidth(f, row.key));
    }
    const e = edge(ui);
    const gap = if (sw > 0) 3 * pad(ui) else 0;
    var any_sub = false;
    for (m.rows[0..m.n]) |row| any_sub = any_sub or row.sub;
    const aw: f32 = if (any_sub) arrowWidth(f, ui) else 0;
    const iw = m.iconColumn(f, ui);
    const w = 2 * e + pad(ui) + iw + lw + gap + sw + pad(ui) + aw;
    const title_h: f32 = if (m.title.len > 0) row_h else 0;
    const sep_h = sepHeight(ui);
    var rows_h: f32 = 0;
    for (m.rows[0..m.n]) |row| rows_h += if (row.sep) sep_h else row_h;
    const h = 2 * e + title_h + rows_h;
    var x = m.at[0];
    var y = m.at[1];
    if (x + w > bounds.x + bounds.w) x = @max(bounds.x, x - w);
    if (y + h > bounds.y + bounds.h) y = @max(bounds.y, y - h);
    m.r = .{ .x = x, .y = y, .w = w, .h = h };
    m.title_r = .{ .x = x + e, .y = y + e, .w = w - 2 * e, .h = title_h };
    var ry = y + e + title_h;
    for (m.row_r[0..m.n], m.rows[0..m.n]) |*rr, row| {
        const rh = if (row.sep) sep_h else row_h;
        rr.* = .{ .x = x + e, .y = ry, .w = w - 2 * e - aw, .h = rh };
        ry += rh;
    }
    for (m.arrow_r[0..m.n], m.row_r[0..m.n]) |*a, row| a.* = .{ .x = row.x + row.w, .y = row.y, .w = aw, .h = row.h };
    // A row that only opens a submenu takes its ▸ too.
    for (m.row_r[0..m.n], m.rows[0..m.n]) |*rr, row| if (row.hover_sub) {
        rr.w += aw;
    };
}

/// A submenu next to `parent`'s row `row`: on the parent's right, else on
/// its left (not over it), kept on screen.
pub fn layoutBeside(m: *Menu, f: *const Gfx.Face, ui: f32, bounds: Rect, parent: *const Menu, row: usize) void {
    m.at = .{ parent.r.x + parent.r.w, parent.row_r[row].y - edge(ui) };
    m.layout(f, ui, bounds);
    if (m.r.x < parent.r.x + parent.r.w and parent.r.x - m.r.w >= bounds.x) {
        m.at[0] = parent.r.x - m.r.w;
        m.layout(f, ui, bounds);
    }
}

/// An icon's size in pixels for face `f` (App draws them this size).
pub fn iconPx(f: *const Gfx.Face) u32 {
    return @intFromFloat(@round(f.cell_h * 1.15));
}

/// Room for icons before the labels: all rows line up when any has one.
fn iconColumn(m: *const Menu, f: *const Gfx.Face, ui: f32) f32 {
    for (m.rows[0..m.n]) |row| if (row.icon != null) return @as(f32, @floatFromInt(iconPx(f))) + @round(pad(ui) * 0.6);
    return 0;
}

fn sepHeight(ui: f32) f32 {
    return @round(9 * ui);
}

fn arrowWidth(f: *const Gfx.Face, ui: f32) f32 {
    return @round(f.cell_w * 2 + 2 * edge(ui));
}

/// The row whose ▸ box is under (x, y).
pub fn arrowAt(m: *const Menu, x: f32, y: f32) ?usize {
    for (m.rows[0..m.n], m.arrow_r[0..m.n], 0..) |row, a, i| if (row.sub and !row.hover_sub and a.contains(x, y)) return i;
    return null;
}

pub fn contains(m: *const Menu, x: f32, y: f32) bool {
    return m.r.contains(x, y);
}

/// The row under (x, y), enabled or not (not on its ▸ box, not a
/// separator).
pub fn rowAt(m: *const Menu, x: f32, y: f32) ?usize {
    for (m.row_r[0..m.n], m.rows[0..m.n], 0..) |rr, row, i| if (!row.sep and rr.contains(x, y)) return i;
    return null;
}

pub fn isEnabled(m: *const Menu, i: usize) bool {
    return i < m.n and m.rows[i].enabled and !m.rows[i].sep;
}

/// Mouse moved: highlight the enabled row under it. True when that changed.
pub fn motion(m: *Menu, x: f32, y: f32) bool {
    var now: ?usize = if (m.rowAt(x, y)) |i| (if (m.isEnabled(i)) i else null) else null;
    var arrow = false;
    if (m.arrowAt(x, y)) |i| if (m.rows[i].sub_on) {
        now = i;
        arrow = true;
    };
    if (now == m.over and arrow == m.over_arrow) return false;
    m.over = now;
    m.over_arrow = arrow;
    return true;
}

pub fn draw(m: *const Menu, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, ui: f32) void {
    gfx.fill(m.r, theme.title_bg);
    gfx.outline(m.r, theme.divider, @max(@round(ui), 1));
    const p = pad(ui);
    const iw = m.iconColumn(f, ui);
    if (m.title.len > 0) {
        const ty = m.title_r.y + @round((m.title_r.h - f.cell_h) / 2);
        _ = gfx.text(f, m.title_r.x + p, ty, m.title, theme.dim);
    }
    for (m.rows[0..m.n], m.row_r[0..m.n], m.arrow_r[0..m.n], 0..) |row, rr, ar, i| {
        if (row.sep) {
            const lw = @max(@round(ui), 1);
            gfx.fill(.{ .x = rr.x + p, .y = rr.y + @round((rr.h - lw) / 2), .w = rr.w - 2 * p, .h = lw }, theme.divider);
            continue;
        }
        if (m.over == i and !m.over_arrow) gfx.fill(rr, theme.focus.mix(theme.title_bg, 0.55));
        if (row.hover_sub) {
            const ac = if (row.sub_on and row.enabled) theme.title_fg else theme.title_fg.mix(theme.title_bg, 0.6);
            _ = gfx.text(f, ar.x + @round((ar.w - f.cell_w) / 2), ar.y + @round((ar.h - f.cell_h) / 2), "▶", ac);
        } else if (row.sub) {
            if (m.over == i and m.over_arrow) gfx.fill(ar, theme.focus.mix(theme.title_bg, 0.55));
            gfx.fill(.{ .x = ar.x, .y = ar.y + @round(ar.h * 0.2), .w = @max(@round(ui), 1), .h = @round(ar.h * 0.6) }, theme.divider);
            const ac = if (row.sub_on) theme.title_fg else theme.title_fg.mix(theme.title_bg, 0.6);
            _ = gfx.text(f, ar.x + @round((ar.w - f.cell_w) / 2), ar.y + @round((ar.h - f.cell_h) / 2), "▶", ac);
        }
        const ty = rr.y + @round((rr.h - f.cell_h) / 2);
        const fg = if (row.enabled) theme.title_fg else theme.title_fg.mix(theme.title_bg, 0.6);
        const kc = if (row.enabled) theme.dim else theme.dim.mix(theme.title_bg, 0.6);
        if (row.icon) |tex| {
            const s: f32 = @floatFromInt(iconPx(f));
            gfx.image(tex, .{ .x = rr.x + p, .y = rr.y + @round((rr.h - s) / 2), .w = s, .h = s });
        }
        _ = gfx.text(f, rr.x + p + iw, ty, row.label, fg);
        // A whole-row submenu's ▸ sits at the row's end: the key before it.
        const kr = if (row.hover_sub) rr.x + rr.w - ar.w else rr.x + rr.w;
        if (row.key.len > 0) _ = gfx.text(f, kr - p - Gfx.textWidth(f, row.key), ty, row.key, kc);
    }
}

/// One line for a menu row: line breaks as ⏎, tabs as spaces, other
/// control characters dropped, cut to `max` characters with …
pub fn oneLine(buf: []u8, text: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var chars: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var prev_cr = false;
    while (it.nextCodepointSlice()) |cs| {
        const cp = std.unicode.utf8Decode(cs) catch ' ';
        if (cp == '\n' and prev_cr) continue; // CR LF: one ⏎
        prev_cr = cp == '\r';
        const out: []const u8 = switch (cp) {
            '\n', '\r' => "⏎",
            '\t' => " ",
            0...8, 0x0b...0x0c, 0x0e...0x1f, 0x7f => continue,
            else => cs,
        };
        if (chars + 1 == max and it.i < text.len) {
            @memcpy(buf[n..][0.."…".len], "…");
            return buf[0 .. n + "…".len];
        }
        if (n + out.len > buf.len) break;
        @memcpy(buf[n..][0..out.len], out);
        n += out.len;
        chars += 1;
    }
    return buf[0..n];
}

test "paste labels: one line, at most 20 characters" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("echo hi⏎ls", oneLine(&buf, "echo hi\r\nls", 20));
    try std.testing.expectEqualStrings("a b", oneLine(&buf, "a\tb", 20));
    try std.testing.expectEqualStrings("12345678901234567890", oneLine(&buf, "12345678901234567890", 20));
    try std.testing.expectEqualStrings("1234567890123456789…", oneLine(&buf, "123456789012345678901", 20));
    try std.testing.expectEqualStrings("✅✅", oneLine(&buf, "✅✅", 20));
}

/// A folder for a menu row: the home folder as ~, and when longer than
/// `max` characters, its end with … in front (the last parts tell most).
pub fn shortPath(buf: []u8, path: []const u8, home: []const u8, max: usize) []const u8 {
    var p = path;
    var tilde = false;
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/')) {
        p = path[home.len..];
        tilde = true;
    }
    const chars = (std.unicode.utf8CountCodepoints(p) catch p.len) + @intFromBool(tilde);
    var n: usize = 0;
    if (chars > max) {
        // "…" + the last max - 1 characters.
        var skip = chars - (max - 1) - @intFromBool(tilde);
        var i: usize = 0;
        while (skip > 0 and i < p.len) : (skip -= 1) i += std.unicode.utf8ByteSequenceLength(p[i]) catch 1;
        p = p[i..];
        tilde = false;
        @memcpy(buf[0.."…".len], "…");
        n = "…".len;
    } else if (tilde) {
        buf[0] = '~';
        n = 1;
    }
    const k = @min(p.len, buf.len - n);
    @memcpy(buf[n..][0..k], p[0..k]);
    return buf[0 .. n + k];
}

test "short paths for menu rows" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("~/src/gtty", shortPath(&buf, "/Users/me/src/gtty", "/Users/me", 40));
    try std.testing.expectEqualStrings("~", shortPath(&buf, "/Users/me", "/Users/me", 40));
    try std.testing.expectEqualStrings("/Users/meg", shortPath(&buf, "/Users/meg", "/Users/me", 40));
    try std.testing.expectEqualStrings("/tmp", shortPath(&buf, "/tmp", "/Users/me", 40));
    try std.testing.expectEqualStrings("…/c/d/eeee", shortPath(&buf, "/Users/me/a/b/c/d/eeee", "/Users/me", 10));
}

test "layout keeps the menu on screen" {
    // Face metrics only; textWidth counts code points × cell width.
    var f: Gfx.Face = undefined;
    f.cell_w = 8;
    f.cell_h = 16;
    var m = Menu.edit(.prompt, .{ 790, 590 }, false, null, true, true, null);
    const screen: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    m.layout(&f, 1, screen);
    try std.testing.expect(m.r.x + m.r.w <= 800 and m.r.y + m.r.h <= 600);
    try std.testing.expect(m.r.x >= 0 and m.r.y >= 0);
    try std.testing.expectEqual(@as(usize, edit_paste), m.rowAt(m.row_r[1].x + 1, m.row_r[1].y + 1).?);
    try std.testing.expect(!m.motion(m.row_r[0].x + 1, m.row_r[0].y + 1)); // Copy is off
    try std.testing.expect(m.motion(m.row_r[1].x + 1, m.row_r[1].y + 1));
    try std.testing.expectEqual(@as(usize, edit_paste), m.over.?);
}

test "a title row sits above the rows and can't be picked" {
    var f: Gfx.Face = undefined;
    f.cell_w = 8;
    f.cell_h = 16;
    var m: Menu = .{ .purpose = .open_with, .at = .{ 10, 10 }, .title = "Open a.txt with" };
    m.add(.{ .label = "TextEdit", .key = "default" });
    m.add(.{ .label = "Xcode" });
    m.layout(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try std.testing.expect(m.rowAt(m.title_r.x + 1, m.title_r.y + 1) == null);
    try std.testing.expectEqual(@as(usize, 1), m.rowAt(m.row_r[1].x + 1, m.row_r[1].y + 1).?);
    try std.testing.expect(m.row_r[0].y >= m.title_r.y + m.title_r.h);
}

test "Paste's ▸ box opens the submenu, the rest of the row pastes" {
    var f: Gfx.Face = undefined;
    f.cell_w = 8;
    f.cell_h = 16;
    var m = Menu.edit(.prompt, .{ 10, 10 }, true, null, true, true, null);
    m.layout(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    const a = m.arrow_r[edit_paste];
    try std.testing.expectEqual(@as(usize, edit_paste), m.arrowAt(a.x + 1, a.y + 1).?);
    try std.testing.expect(m.rowAt(a.x + 1, a.y + 1) == null);
    try std.testing.expect(m.arrowAt(m.row_r[edit_paste].x + 1, a.y + 1) == null);
    try std.testing.expect(m.arrowAt(m.arrow_r[edit_copy].x + 1, m.arrow_r[edit_copy].y + 1) == null); // Copy has none
    _ = m.motion(a.x + 1, a.y + 1);
    try std.testing.expect(m.over_arrow);
}

test "the right-click menu of a job window: Copy last output under Copy" {
    const m = Menu.edit(.{ .job = 7 }, .{ 10, 10 }, false, "Copy last output", true, false, false);
    try std.testing.expectEqual(@as(usize, 5), m.n);
    try std.testing.expectEqualStrings("Copy last output", m.rows[1].label);
    try std.testing.expectEqual(@as(i32, edit_output), m.codes[1]);
    try std.testing.expectEqual(@as(i32, edit_paste), m.codes[2]);
    try std.testing.expectEqual(@as(i32, edit_folders), m.codes[3]);
    try std.testing.expectEqual(@as(i32, edit_new_shell), m.codes[4]);
}

test "separators take no clicks; a whole-row submenu takes its ▸" {
    var f: Gfx.Face = undefined;
    f.cell_w = 8;
    f.cell_h = 16;
    var m: Menu = .{ .purpose = .open_with, .at = .{ 10, 10 } };
    m.add(.{ .label = "Open" });
    m.add(.{ .label = "Open With", .sub = true, .sub_on = true, .hover_sub = true });
    m.add(separator);
    m.add(.{ .label = "Other…" });
    m.layout(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try std.testing.expect(m.row_r[2].h < m.row_r[1].h);
    try std.testing.expect(m.rowAt(m.row_r[2].x + 1, m.row_r[2].y + 1) == null);
    try std.testing.expect(!m.isEnabled(2));
    try std.testing.expectEqual(m.row_r[2].y + m.row_r[2].h, m.row_r[3].y);
    const a = m.arrow_r[1];
    try std.testing.expect(m.arrowAt(a.x + 1, a.y + 1) == null);
    try std.testing.expectEqual(@as(usize, 1), m.rowAt(a.x + 1, a.y + 1).?);
    var sub: Menu = .{ .purpose = .open_with, .at = .{ 0, 0 } };
    sub.add(.{ .label = "TextEdit" });
    sub.layoutBeside(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, &m, 1);
    try std.testing.expect(sub.r.x >= m.r.x + m.r.w);
    // No room on the right: on the left, not over the menu.
    var right = m;
    right.at = .{ 790, 10 };
    right.layout(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    sub.layoutBeside(&f, 1, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, &right, 1);
    try std.testing.expect(sub.r.x + sub.r.w <= right.r.x);
}
