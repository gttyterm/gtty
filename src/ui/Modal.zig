// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A modal dialog: asks the user before gtty does something (a file
//! dropped in: copy it?). A title, a few lines of text, up to three
//! buttons. It always has a timeout: with no answer by then, the
//! `safe` button is taken (the less critical choice: for a copy, not
//! copying). A bar along its bottom and "Cancel in 7 s" show the time
//! left.
//!
//! Keys: Enter = the focused button (at first the `default` one),
//! ←/→/Tab move the focus, Esc = the safe button; other keys do nothing.
//!
//! With an input field (`Spec.input`: renaming a file) the keys edit it
//! (LineEdit: arrows, words, Home / End, Shift selects, Backspace /
//! Delete, typing and pasting replace the selection), Enter = the default
//! button, Esc = the safe one; any change starts the countdown again.
//! `anchor`: shown by that rect (the file's name on screen) instead of
//! centered. `setError`: a red line under the text (the dialog stays).
//! The mouse: a click on a button picks it; anywhere else does nothing.
//! App owns it (`App.modal`, with what it is for: `App.modal_job`),
//! routes keys / clicks to it while it is open, asks `expired` each
//! frame and acts on the button picked (`App.resolveModal`).

const std = @import("std");
const Gfx = @import("../render/Gfx.zig");
const color = @import("../core/color.zig");
const c = @import("../c.zig").c;
const LineEdit = @import("LineEdit.zig");

const Modal = @This();
const Rect = Gfx.Rect;
const Theme = color.Theme;

pub const max_buttons = 3;
pub const default_timeout_ms: u64 = 10_000;

pub const Kind = enum { normal, primary, danger };

pub const Button = struct {
    label: []const u8,
    kind: Kind = .normal,
};

pub const Spec = struct {
    title: []const u8,
    /// Lines separated by '\n'.
    body: []const u8,
    buttons: []const Button,
    /// The button Enter picks at first (focused).
    default: usize,
    /// The less critical choice: taken on timeout and by Esc.
    safe: usize,
    timeout_ms: u64 = default_timeout_ms,
    /// An input field with this text (then Enter = `default`).
    input: ?[]const u8 = null,
    /// Its selection at first: the name up to its last dot.
    select_stem: bool = false,
    /// Shown by this rect (under it, else over it) instead of centered.
    anchor: ?Rect = null,
};

const Text = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn set(t: *Text, s: []const u8) void {
        t.len = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
        while (t.len > 0 and t.len < s.len and (t.buf[t.len] & 0xC0) == 0x80) t.len -= 1;
    }

    fn get(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

title: Text = .{},
body: Text = .{},
labels: [max_buttons]Text = [_]Text{.{}} ** max_buttons,
kinds: [max_buttons]Kind = [_]Kind{.normal} ** max_buttons,
n: usize = 0,
focus: usize = 0,
safe: usize = 0,
timeout_ms: u64,
/// When it opened, or the field last changed (the countdown's start).
opened_ms: u64,
edit: ?LineEdit = null,
anchor: ?Rect = null,
err: Text = .{},
/// Where it was drawn last (clicks).
box: Rect = .{},
btn_r: [max_buttons]Rect = [_]Rect{.{}} ** max_buttons,

pub fn init(spec: Spec, now: u64) Modal {
    var m: Modal = .{ .timeout_ms = @max(spec.timeout_ms, 1000), .opened_ms = now };
    m.title.set(spec.title);
    m.body.set(spec.body);
    m.n = @min(spec.buttons.len, max_buttons);
    for (spec.buttons[0..m.n], 0..) |b, i| {
        m.labels[i].set(b.label);
        m.kinds[i] = b.kind;
    }
    m.focus = @min(spec.default, m.n -| 1);
    m.safe = @min(spec.safe, m.n -| 1);
    m.anchor = spec.anchor;
    if (spec.input) |t| {
        m.edit = LineEdit.init(t);
        if (spec.select_stem) m.edit.?.selectStem() else m.edit.?.selectAll();
    }
    return m;
}

/// The field's text (UTF-8, in `buf`).
pub fn inputText(m: *const Modal, buf: []u8) []const u8 {
    const e = if (m.edit) |*e| e else return "";
    return e.text(buf);
}

/// A red line under the text (empty: none); the dialog stays open.
pub fn setError(m: *Modal, text: []const u8, now: u64) void {
    m.err.set(text);
    m.opened_ms = now;
}

/// Typed or pasted text, into the field.
pub fn typed(m: *Modal, s: []const u8, now: u64) void {
    const e = if (m.edit) |*e| e else return;
    e.insert(s);
    m.err.set("");
    m.opened_ms = now;
}

/// No answer in time: the caller takes `safe`.
pub fn expired(m: *const Modal, now: u64) bool {
    return now -| m.opened_ms >= m.timeout_ms;
}

/// A key (SDL key code and modifiers): the button it picks, if any.
pub fn key(m: *Modal, k: c.SDL_Keycode, mod: c.SDL_Keymod, now: u64) ?usize {
    switch (k) {
        c.SDLK_RETURN, c.SDLK_KP_ENTER => return m.focus,
        c.SDLK_ESCAPE => return m.safe,
        else => {},
    }
    if (m.edit) |*e| {
        const shift = mod & c.SDL_KMOD_SHIFT != 0;
        const cmd = mod & c.SDL_KMOD_GUI != 0;
        const word = mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL) != 0;
        switch (k) {
            c.SDLK_LEFT => e.move(if (cmd) .home else if (word) .word_left else .left, shift),
            c.SDLK_RIGHT => e.move(if (cmd) .end else if (word) .word_right else .right, shift),
            c.SDLK_HOME, c.SDLK_UP => e.move(.home, shift),
            c.SDLK_END, c.SDLK_DOWN => e.move(.end, shift),
            c.SDLK_BACKSPACE => if (cmd) {
                e.move(.home, true);
                e.backspace(false);
            } else e.backspace(word),
            c.SDLK_DELETE => e.delete(word),
            c.SDLK_A => if (cmd or mod & c.SDL_KMOD_CTRL != 0) e.selectAll() else return null,
            else => return null,
        }
        m.err.set("");
        m.opened_ms = now;
        return null;
    }
    switch (k) {
        c.SDLK_LEFT => m.focus = if (m.focus == 0) m.n - 1 else m.focus - 1,
        c.SDLK_RIGHT, c.SDLK_TAB => m.focus = (m.focus + 1) % m.n,
        else => {},
    }
    return null;
}

/// A left click: the button under it, if any.
pub fn click(m: *const Modal, x: f32, y: f32) ?usize {
    for (m.btn_r[0..m.n], 0..) |r, i| if (r.contains(x, y)) return i;
    return null;
}

/// The input field: its text (scrolled to keep the cursor in view), the
/// selection, the cursor.
fn drawField(e: *const LineEdit, gfx: *Gfx, t: *const Theme, font: *Gfx.Face, r: Rect, ui: f32, restore: Rect) void {
    gfx.fill(r, t.prompt_bg);
    gfx.outline(r, t.focus, @max(@round(ui), 1));
    const inner = r.inset(@round(6 * ui));
    gfx.clip(inner);
    defer gfx.clip(restore);
    const cols: usize = @intFromFloat(@max(@floor(inner.w / font.cell_w), 1));
    const first: usize = if (e.cursor + 1 > cols) e.cursor + 1 - cols else 0;
    const ty = r.y + @round((r.h - font.cell_h) / 2);
    const sel = e.selection();
    if (sel[1] > sel[0]) {
        const a = @max(sel[0], first);
        if (sel[1] > a) gfx.fill(.{
            .x = inner.x + @as(f32, @floatFromInt(a - first)) * font.cell_w,
            .y = ty,
            .w = @as(f32, @floatFromInt(sel[1] - a)) * font.cell_w,
            .h = font.cell_h,
        }, t.selection);
    }
    var x = inner.x;
    for (e.chars()[first..]) |cp| {
        if (x > inner.x + inner.w) break;
        gfx.glyphAt(font, x, ty, cp, t.prompt_fg);
        x += font.cell_w;
    }
    const cx = inner.x + @as(f32, @floatFromInt(e.cursor - first)) * font.cell_w;
    gfx.fill(.{ .x = cx, .y = ty, .w = @max(@round(2 * ui), 1), .h = font.cell_h }, t.cursor);
}

/// Draw it centered in `area` over a dimmed `screen` (fonts: `font` for
/// the text and buttons, `small` for the title and the countdown).
pub fn draw(m: *Modal, gfx: *Gfx, t: *const Theme, font: *Gfx.Face, small: *Gfx.Face, screen: Rect, area: Rect, mouse: ?[2]f32, ui: f32, now: u64) void {
    gfx.fillAlpha(screen, t.desktop, 150);
    const pad = @round(14 * ui);
    const line_h = @round(font.cell_h * 1.3);
    const title_h = @round(small.cell_h * 1.8);
    const btn_h = @round(font.cell_h * 1.6);
    const bar_h = @max(@round(3 * ui), 2);

    var lines: usize = 0;
    var text_w: f32 = Gfx.textWidth(small, m.title.get());
    var it = std.mem.splitScalar(u8, m.body.get(), '\n');
    while (it.next()) |l| {
        lines += 1;
        text_w = @max(text_w, Gfx.textWidth(font, l));
    }
    var btns_w: f32 = 0;
    for (m.labels[0..m.n]) |*l| btns_w += Gfx.textWidth(font, l.get()) + 2 * pad + pad / 2;
    var cbuf: [96]u8 = undefined;
    const left_s = (m.timeout_ms -| (now -| m.opened_ms) + 999) / 1000;
    const countdown = std.fmt.bufPrint(&cbuf, "{s} in {d} s", .{ m.labels[m.safe].get(), left_s }) catch "";
    const foot_w = btns_w + Gfx.textWidth(small, countdown) + 2 * pad;
    const field_h = if (m.edit != null) @round(font.cell_h * 1.7) + pad * 0.6 else 0;
    const err_h = if (m.err.len > 0) line_h else 0;
    if (m.err.len > 0) text_w = @max(text_w, Gfx.textWidth(font, m.err.get()));
    if (m.edit) |*e| text_w = @max(text_w, @min(@as(f32, @floatFromInt(e.len + 2)) * font.cell_w, 560 * ui));

    const bw = @min(@max(@max(text_w, foot_w) + 2 * pad, @round(360 * ui)), screen.w - 2 * pad);
    const bh = title_h + pad + @as(f32, @floatFromInt(lines)) * line_h + field_h + err_h + pad + btn_h + pad + bar_h;
    // By the anchor (under it, else over it), else centered in `area`.
    var bx = area.x + (area.w - bw) / 2;
    var by = area.y + (area.h - bh) / 2;
    if (m.anchor) |a| {
        bx = a.x - pad;
        by = a.y + a.h + @round(4 * ui);
        if (by + bh > screen.y + screen.h) by = a.y - @round(4 * ui) - bh;
    }
    const box: Rect = .{
        .x = @round(std.math.clamp(bx, screen.x, screen.x + screen.w - bw)),
        .y = @round(std.math.clamp(by, screen.y, screen.y + screen.h - bh)),
        .w = @round(bw),
        .h = @round(bh),
    };
    m.box = box;
    gfx.fill(.{ .x = box.x + @round(3 * ui), .y = box.y + @round(4 * ui), .w = box.w, .h = box.h }, t.desktop); // shadow
    gfx.fill(box, t.bg);
    gfx.fill(.{ .x = box.x, .y = box.y, .w = box.w, .h = title_h }, t.title_bg);
    gfx.outline(box, t.focus, @max(@round(ui), 1));
    gfx.clip(box);
    defer gfx.clip(null);
    _ = gfx.text(small, box.x + pad, box.y + @round((title_h - small.cell_h) / 2), m.title.get(), t.title_fg);

    var y = box.y + title_h + pad;
    it = std.mem.splitScalar(u8, m.body.get(), '\n');
    var first = true;
    while (it.next()) |l| {
        _ = gfx.text(font, box.x + pad, y + @round((line_h - font.cell_h) / 2), l, if (first) t.prompt_fg else t.dim);
        first = false;
        y += line_h;
    }
    if (m.edit) |*e| {
        const fr: Rect = .{ .x = box.x + pad, .y = y + pad * 0.3, .w = box.w - 2 * pad, .h = @round(font.cell_h * 1.7) };
        drawField(e, gfx, t, font, fr, ui, box);
        y += field_h;
    }
    if (m.err.len > 0) {
        _ = gfx.text(font, box.x + pad, y + @round((line_h - font.cell_h) / 2), m.err.get(), t.stderr_accent);
        y += line_h;
    }
    y += pad;

    // Buttons, right-aligned in order; the countdown on the left.
    var x = box.x + box.w - pad;
    var i = m.n;
    while (i > 0) {
        i -= 1;
        const label = m.labels[i].get();
        const w = Gfx.textWidth(font, label) + 2 * pad;
        x -= w;
        const r: Rect = .{ .x = x, .y = y, .w = w, .h = btn_h };
        m.btn_r[i] = r;
        x -= pad / 2;
        const over = if (mouse) |p| r.contains(p[0], p[1]) else false;
        const accent = switch (m.kinds[i]) {
            .normal => t.title_bg,
            .primary => t.focus,
            .danger => t.stderr_accent,
        };
        const base = if (m.kinds[i] == .normal) t.title_bg else t.title_bg.mix(accent, 0.45);
        gfx.fill(r, if (over) base.mix(t.focus, 0.3) else base);
        if (i == m.focus) {
            gfx.outline(r, t.focus, @max(@round(2 * ui), 1));
        } else gfx.outline(r, t.divider, @max(@round(ui), 1));
        _ = gfx.text(font, r.x + pad, r.y + @round((btn_h - font.cell_h) / 2), label, t.prompt_fg);
    }
    _ = gfx.text(small, box.x + pad, y + @round((btn_h - small.cell_h) / 2), countdown, t.dim);

    // The time left: a bar along the bottom, shrinking to the right.
    const left = 1 - @as(f32, @floatFromInt(@min(now -| m.opened_ms, m.timeout_ms))) / @as(f32, @floatFromInt(m.timeout_ms));
    gfx.fill(.{ .x = box.x, .y = box.y + box.h - bar_h, .w = @round(box.w * left), .h = bar_h }, t.focus);
}
