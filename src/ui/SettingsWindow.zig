// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The settings window: an OS window of its own (next to gtty's), opened
//! from the gtty menu's Settings… or the `settings` command, like a
//! terminal's profile settings. Tabs along the top, one group of settings
//! per tab: General, Colors, Timing, AI.
//!
//! It edits App's Config directly; every change is queued in `changes` and
//! App applies it at once (and saves the file). Numbers: [−] value [+], or
//! click the value and type one; text and colors (#rrggbb): click the
//! field and type, Enter / Tab / a click elsewhere keeps it, Esc undoes.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const color = @import("../core/color.zig");
const Rgb = color.Rgb;
const Theme = color.Theme;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const Config = @import("../core/Config.zig");
const Ai = @import("../ai/Ai.zig");

const SettingsWindow = @This();

pub const Tab = enum { general, colors, timing, ai };
const tab_names = [_][]const u8{ "General", "Colors", "Timing", "AI" };

/// What changed (App applies it and saves).
pub const Change = union(enum) {
    num: usize, // Config.nums index
    command,
    colors_default,
    color: usize, // Config.color_keys index
    colors_reset,
    marks,
    file_opener,
    quit_on_last_shell,
    /// An AI setting (read at each request).
    ai,
    /// "Forget": empty the AI's local memory.
    ai_forget,
};

/// A field being typed into.
const Field = union(enum) { num: usize, command, color: usize, ai: Config.AiText };

const Edit = struct {
    field: Field,
    buf: [Config.max_text]u8 = undefined,
    len: usize = 0,
    /// Just clicked: the old text is selected; typing replaces it,
    /// Backspace clears it.
    fresh: bool = true,
};

/// What a click on a spot does.
const Ctl = union(enum) {
    tab: usize,
    minus: usize,
    plus: usize,
    field: Field,
    colors_default,
    colors_reset,
    marks,
    file_opener,
    quit_on_last_shell,
    ai_provider,
    ai_memory,
    ai_forget,
};

const max_ctls = 64;

gpa: std.mem.Allocator,
window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
gfx: Gfx,
id: c.SDL_WindowID,
cfg: *Config,
tab: usize = 0,
edit: ?Edit = null,
/// Last save failed: said in the footer.
save_failed: bool = false,
/// Close asked for (its close button, Esc, ⌘W): App closes it.
want_close: bool = false,
/// Script hook `/shot` while `/target settings`: saved on the next draw
/// (before it is shown); `shot_ok` says how it went.
shot_path: ?[:0]u8 = null,
shot_ok: ?bool = null,
dirty: bool = true,
density: f32 = 1,
ui: f32 = 1,
over: ?usize = null,
ctls: [max_ctls]struct { r: Rect, what: Ctl } = undefined,
n_ctls: usize = 0,
changes: [16]Change = undefined,
n_changes: usize = 0,

/// Point size of the window's text (fixed: gtty's text size is a setting
/// shown here; changing it shouldn't resize the settings themselves).
const font_pt = 13;

pub fn open(gpa: std.mem.Allocator, cfg: *Config) !*SettingsWindow {
    const window = c.SDL_CreateWindow("gtty Settings", 680, 620, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse
        return error.SdlWindow;
    errdefer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, 520, 420);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer;
    errdefer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderVSync(renderer, 1);
    _ = c.SDL_StartTextInput(window);
    const s = try gpa.create(SettingsWindow);
    s.* = .{
        .gpa = gpa,
        .window = window,
        .renderer = renderer,
        .gfx = try Gfx.init(gpa, renderer),
        .id = c.SDL_GetWindowID(window),
        .cfg = cfg,
    };
    s.updateScale();
    return s;
}

pub fn close(s: *SettingsWindow) void {
    if (s.shot_path) |p| s.gpa.free(p);
    s.gfx.deinit();
    c.SDL_DestroyRenderer(s.renderer);
    c.SDL_DestroyWindow(s.window);
    s.gpa.destroy(s);
}

/// Bring the (already open) window to the front.
pub fn raise(s: *SettingsWindow) void {
    _ = c.SDL_RaiseWindow(s.window);
}

fn updateScale(s: *SettingsWindow) void {
    s.density = c.SDL_GetWindowPixelDensity(s.window);
    if (s.density <= 0) s.density = 1;
    s.ui = c.SDL_GetWindowDisplayScale(s.window);
    if (s.ui <= 0) s.ui = s.density;
    s.dirty = true;
}

/// The queued changes, oldest first; App empties it.
pub fn takeChanges(s: *SettingsWindow) []const Change {
    const out = s.changes[0..s.n_changes];
    s.n_changes = 0;
    return out;
}

fn changed(s: *SettingsWindow, ch: Change) void {
    if (s.n_changes < s.changes.len) {
        s.changes[s.n_changes] = ch;
        s.n_changes += 1;
    }
    s.dirty = true;
}

// ------------------------------------------------------------ events

/// An SDL event for this window (App routes by window id). Coordinates
/// are in window units, as SDL gives them.
pub fn handle(s: *SettingsWindow, ev: *const c.SDL_Event) void {
    switch (ev.type) {
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        => s.updateScale(),
        c.SDL_EVENT_WINDOW_EXPOSED => s.dirty = true,
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => s.want_close = true,
        c.SDL_EVENT_TEXT_INPUT => s.onText(std.mem.span(ev.text.text)),
        c.SDL_EVENT_KEY_DOWN => s.onKey(ev.key.key, ev.key.mod),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT)
            s.onClick(ev.button.x * s.density, ev.button.y * s.density),
        c.SDL_EVENT_MOUSE_MOTION => s.onMotion(ev.motion.x * s.density, ev.motion.y * s.density),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => s.onMotion(-1, -1),
        else => {},
    }
}

pub fn onText(s: *SettingsWindow, text: []const u8) void {
    const e = if (s.edit) |*e| e else return;
    if (e.fresh) e.len = 0;
    e.fresh = false;
    const room = e.buf.len - e.len;
    const n = @min(room, text.len);
    @memcpy(e.buf[e.len..][0..n], text[0..n]);
    e.len += n;
    s.dirty = true;
}

pub fn onKey(s: *SettingsWindow, key: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    const cmd = if (builtin.os.tag == .macos) mod & c.SDL_KMOD_GUI != 0 else mod & c.SDL_KMOD_CTRL != 0;
    if (s.edit) |*e| {
        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_TAB => s.commit(),
            c.SDLK_ESCAPE => s.edit = null,
            c.SDLK_BACKSPACE => {
                if (e.fresh) e.len = 0;
                e.fresh = false;
                // Back one UTF-8 character.
                while (e.len > 0) {
                    e.len -= 1;
                    if (e.buf[e.len] & 0xC0 != 0x80) break;
                }
            },
            c.SDLK_V => if (cmd) {
                if (c.SDL_GetClipboardText()) |t| {
                    defer c.SDL_free(t);
                    const line = std.mem.sliceTo(t, 0);
                    s.onText(line[0 .. std.mem.indexOfAny(u8, line, "\r\n") orelse line.len]);
                }
            },
            else => {},
        }
        s.dirty = true;
        return;
    }
    switch (key) {
        c.SDLK_ESCAPE => s.want_close = true,
        c.SDLK_W => if (cmd) {
            s.want_close = true;
        },
        // Ctrl+Tab / Ctrl+Shift+Tab: next / previous tab.
        c.SDLK_TAB => if (mod & c.SDL_KMOD_CTRL != 0) {
            const n = s.tabCount();
            s.tab = if (mod & c.SDL_KMOD_SHIFT != 0) (s.tab + n - 1) % n else (s.tab + 1) % n;
            s.dirty = true;
        },
        else => {},
    }
}

fn onMotion(s: *SettingsWindow, x: f32, y: f32) void {
    const now = s.ctlAt(x, y);
    if (now != s.over) {
        s.over = now;
        s.dirty = true;
    }
}

fn ctlAt(s: *const SettingsWindow, x: f32, y: f32) ?usize {
    for (s.ctls[0..s.n_ctls], 0..) |ct, i| if (ct.r.contains(x, y)) return i;
    return null;
}

pub fn onClick(s: *SettingsWindow, x: f32, y: f32) void {
    const hit: ?Ctl = if (s.ctlAt(x, y)) |i| s.ctls[i].what else null;
    // A click anywhere but the field being typed into keeps what was typed.
    if (s.edit) |e| {
        const same = if (hit) |h| h == .field and std.meta.eql(h.field, e.field) else false;
        if (same) return;
        s.commit();
    }
    const what = hit orelse return;
    s.dirty = true;
    switch (what) {
        .tab => |t| s.tab = t,
        .minus, .plus => |i| {
            const n = Config.nums[i];
            const v = s.cfg.getNum(i) + if (what == .plus) n.step else -n.step;
            s.cfg.setNum(i, v);
            s.changed(.{ .num = i });
        },
        .field => |f| s.startEdit(f),
        .colors_default => {
            s.cfg.colors = !s.cfg.colors;
            s.changed(.colors_default);
        },
        .marks => {
            s.cfg.marks = !s.cfg.marks;
            s.changed(.marks);
        },
        .file_opener => {
            s.cfg.file_opener = !s.cfg.file_opener;
            s.changed(.file_opener);
        },
        .quit_on_last_shell => {
            s.cfg.quit_on_last_shell = !s.cfg.quit_on_last_shell;
            s.changed(.quit_on_last_shell);
        },
        .ai_provider => {
            const n = Config.AiProvider.names.len;
            s.cfg.ai_provider = @enumFromInt((@intFromEnum(s.cfg.ai_provider) + 1) % n);
            s.changed(.ai);
        },
        .ai_memory => {
            s.cfg.ai_memory = !s.cfg.ai_memory;
            s.changed(.ai);
        },
        .ai_forget => s.changed(.ai_forget),
        .colors_reset => {
            const d: Config = .{};
            s.cfg.fg = d.fg;
            s.cfg.bg = d.bg;
            s.cfg.palette = d.palette;
            s.cfg.mark_input = d.mark_input;
            s.cfg.mark_ai = d.mark_ai;
            s.changed(.colors_reset);
        },
    }
}

fn startEdit(s: *SettingsWindow, f: Field) void {
    var e: Edit = .{ .field = f };
    var w: std.Io.Writer = .fixed(&e.buf);
    switch (f) {
        .num => |i| w.print("{d}", .{s.cfg.getNum(i)}) catch {},
        .command => w.writeAll(s.cfg.command()) catch {},
        .ai => |t| w.writeAll(s.cfg.aiText(t)) catch {},
        .color => |i| {
            const rgb = s.cfg.colorAt(i);
            w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch {};
        },
    }
    e.len = w.buffered().len;
    s.edit = e;
}

/// Keep what was typed (a bad number or color: the old value stays).
fn commit(s: *SettingsWindow) void {
    const e = s.edit orelse return;
    s.edit = null;
    s.dirty = true;
    const text = std.mem.trim(u8, e.buf[0..e.len], " \t");
    switch (e.field) {
        .num => |i| {
            const v = std.fmt.parseFloat(f64, text) catch return;
            s.cfg.setNum(i, v);
            s.changed(.{ .num = i });
        },
        .command => {
            if (std.mem.eql(u8, text, s.cfg.command())) return;
            s.cfg.setCommand(text);
            s.changed(.command);
        },
        .ai => |t| {
            if (std.mem.eql(u8, text, s.cfg.aiText(t))) return;
            s.cfg.setAiText(t, text);
            s.changed(.ai);
        },
        .color => |i| {
            const rgb = Config.parseRgb(text) orelse return;
            s.cfg.colorPtr(i).* = rgb;
            s.changed(.{ .color = i });
        },
    }
}

fn tabCount(s: *const SettingsWindow) usize {
    _ = s;
    return tab_names.len;
}

fn tabName(i: usize) []const u8 {
    return if (i < tab_names.len) tab_names[i] else "";
}

// ------------------------------------------------------------ drawing

fn addCtl(s: *SettingsWindow, r: Rect, what: Ctl) void {
    if (s.n_ctls == max_ctls) return;
    s.ctls[s.n_ctls] = .{ .r = r, .what = what };
    s.n_ctls += 1;
}

fn isOver(s: *const SettingsWindow, what: Ctl) bool {
    const i = s.over orelse return false;
    return i < s.n_ctls and std.meta.eql(s.ctls[i].what, what);
}

/// Draw everything (when dirty); `theme` is gtty's, for the chrome.
pub fn render(s: *SettingsWindow, theme: *const Theme) void {
    if (!s.dirty) return;
    s.dirty = false;
    var wp: c_int = 0;
    var hp: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(s.window, &wp, &hp);
    const W: f32 = @floatFromInt(wp);
    const H: f32 = @floatFromInt(hp);
    const ui = s.ui;
    const f = s.gfx.face(@intFromFloat(@round(font_pt * ui))) catch return;
    const small = s.gfx.face(@intFromFloat(@round(font_pt * 0.85 * ui))) catch return;
    const g = &s.gfx;
    s.n_ctls = 0;

    g.fill(.{ .w = W, .h = H }, theme.desktop);

    // Tabs.
    const pad = @round(14 * ui);
    const tab_h = @round(f.cell_h * 2.2);
    g.fill(.{ .w = W, .h = tab_h }, theme.title_bg);
    var tx = pad;
    for (0..s.tabCount()) |i| {
        const name = tabName(i);
        const tw = Gfx.textWidth(f, name) + 2 * pad;
        const r: Rect = .{ .x = tx, .y = 0, .w = tw, .h = tab_h };
        const on = i == s.tab;
        if (on) g.fill(r, theme.desktop) else if (s.isOver(.{ .tab = i })) g.fill(r, theme.title_bg.mix(theme.focus, 0.15));
        if (on) g.fill(.{ .x = r.x, .y = 0, .w = r.w, .h = @max(@round(2 * ui), 1) }, theme.focus);
        _ = g.text(f, r.x + pad, @round((tab_h - f.cell_h) / 2), name, if (on) theme.prompt_fg else theme.dim);
        s.addCtl(r, .{ .tab = i });
        tx += tw;
    }

    var y = tab_h + pad;
    const row_h = @round(f.cell_h * 2.1);
    const label_x = pad * 1.5;
    const ctl_x = @round(@max(W * 0.42, label_x + 24 * f.cell_w));
    switch (s.tab) {
        0 => {
            y = s.numRow(f, small, theme, y, row_h, label_x, ctl_x, Config.numIndex("font-size").?, "Text size", "pt");
            y = s.numRow(f, small, theme, y, row_h, label_x, ctl_x, Config.numIndex("scrollback").?, "Scrollback", "lines, new windows");
            y = s.checkRow(f, theme, y, row_h, label_x, ctl_x, "Colors in new windows", s.cfg.colors, .colors_default);
            y = s.checkRow(f, theme, y, row_h, label_x, ctl_x, "File names: mark on hover, double-click opens", s.cfg.file_opener, .file_opener);
            y = s.checkRow(f, theme, y, row_h, label_x, ctl_x, "Quit gtty when the last shell closes", s.cfg.quit_on_last_shell, .quit_on_last_shell);
            y += @round(row_h * 0.3);
            _ = g.text(f, label_x, y + @round((row_h - f.cell_h) / 2), "Start-up command", theme.title_fg);
            const fw = @min(W - ctl_x - pad, 30 * f.cell_w);
            s.fieldBox(f, theme, .{ .x = ctl_x, .y = y + @round(row_h * 0.12), .w = fw, .h = @round(row_h * 0.76) }, .command, s.cfg.command());
            y += row_h;
            _ = g.text(small, ctl_x, y, "at the next start; s = your shell, empty = none", theme.dim);
            // Left-edge marks of the rows: typed / AI.
            y += @round(small.cell_h * 1.6) + @round(row_h * 0.3);
            y = s.checkRow(f, theme, y, row_h, label_x, ctl_x, "Marks on the left edge", s.cfg.marks, .marks);
            y = s.numRow(f, small, theme, y, row_h, label_x, ctl_x, Config.numIndex("mark-width").?, "Mark width", "px");
            const sw = @round(row_h * 0.62);
            const cfw = 9 * f.cell_w;
            y = s.colorRow(f, theme, y, row_h, label_x, ctl_x, Config.mark_color_first, "Typed (input)", sw, cfw);
            y = s.colorRow(f, theme, y, row_h, label_x, ctl_x, Config.mark_color_first + 1, "AI", sw, cfw);
        },
        1 => {
            const sw = @round(row_h * 0.62);
            const fw = 9 * f.cell_w;
            y = s.colorRow(f, theme, y, row_h, label_x, ctl_x, 0, "Text", sw, fw);
            y = s.colorRow(f, theme, y, row_h, label_x, ctl_x, 1, "Background", sw, fw);
            y += @round(row_h * 0.3);
            _ = g.text(small, label_x, y, "normal 0–7", theme.dim);
            const col2 = @round(@max(W * 0.52, label_x + 4 * f.cell_w + sw + fw + 4 * pad));
            _ = g.text(small, col2, y, "bright 8–15", theme.dim);
            y += @round(small.cell_h * 1.6);
            const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
            for (0..8) |k| {
                const ry = y + row_h * @as(f32, @floatFromInt(k));
                _ = s.colorRow(f, theme, ry, row_h, label_x, label_x + 9 * f.cell_w, 2 + k, names[k], sw, fw);
                _ = s.colorRow(f, theme, ry, row_h, col2, col2 + 9 * f.cell_w, 10 + k, names[k], sw, fw);
            }
            y += row_h * 8 + @round(row_h * 0.3);
            const label = "Reset colors";
            const br: Rect = .{ .x = label_x, .y = y, .w = Gfx.textWidth(f, label) + 2 * pad, .h = @round(row_h * 0.8) };
            s.button(f, theme, br, label, .colors_reset);
        },
        2 => {
            const rows = [_]struct { key: []const u8, label: []const u8 }{
                .{ .key = "anim-ms", .label = "Window animation" },
                .{ .key = "tooltip-ms", .label = "Tooltip after" },
                .{ .key = "chip-hover-ms", .label = "Chip peek after" },
                .{ .key = "peek-close-ms", .label = "Peek closes after" },
                .{ .key = "kill-grace-ms", .label = "Kill: force after" },
            };
            for (rows) |r| y = s.numRow(f, small, theme, y, row_h, label_x, ctl_x, Config.numIndex(r.key).?, r.label, "ms");
            y += @round(row_h * 0.2);
            _ = g.text(small, label_x, y, "0 ms animation: no transitions. Kill: SIGHUP first, SIGKILL after this.", theme.dim);
        },
        3 => s.aiTab(f, small, theme, y, row_h, label_x, ctl_x, W, pad),
        else => {},
    }

    // Footer: where the settings are saved.
    const fy = H - @round(small.cell_h * 2);
    var pbuf: [4096]u8 = undefined;
    var nbuf: [4200]u8 = undefined;
    const note = if (s.save_failed)
        std.fmt.bufPrint(&nbuf, "could not save {s}", .{Config.path(&pbuf) orelse "the settings"}) catch ""
    else if (Config.path(&pbuf)) |p|
        (if (underHome(p)) |rest| std.fmt.bufPrint(&nbuf, "saved in ~{s}", .{rest}) else std.fmt.bufPrint(&nbuf, "saved in {s}", .{p})) catch ""
    else
        "not saved (no home folder)";
    // Too long: keep the end ("…" + the last characters that fit).
    const fit: usize = @intFromFloat(@max((W - 2 * label_x) / small.cell_w, 4));
    const n_cp = std.unicode.utf8CountCodepoints(note) catch note.len;
    var shown = note;
    if (n_cp > fit) {
        var skip = n_cp - fit + 1;
        var k: usize = 0;
        while (skip > 0 and k < note.len) : (skip -= 1) k += std.unicode.utf8ByteSequenceLength(note[k]) catch 1;
        const fx = g.text(small, label_x, fy, "…", theme.dim);
        _ = g.text(small, fx, fy, note[k..], if (s.save_failed) theme.stderr_accent else theme.dim);
        shown = "";
    }
    if (shown.len > 0) _ = g.text(small, label_x, fy, shown, if (s.save_failed) theme.stderr_accent else theme.dim);

    if (s.shot_path) |path| {
        s.shot_path = null;
        defer s.gpa.free(path);
        s.shot_ok = false;
        if (c.SDL_RenderReadPixels(s.renderer, null)) |surf| {
            defer c.SDL_DestroySurface(surf);
            s.shot_ok = c.SDL_SaveBMP(surf, path.ptr);
        }
    }
    _ = c.SDL_RenderPresent(s.renderer);
}

/// The AI tab: provider (click to change), model, endpoint, API key, the
/// local memory; notes on what is sent. (No way to change the system
/// prompt.)
fn aiTab(s: *SettingsWindow, f: *Gfx.Face, small: *Gfx.Face, theme: *const Theme, y_in: f32, row_h: f32, label_x: f32, ctl_x: f32, W: f32, pad: f32) void {
    const g = &s.gfx;
    var y = y_in;
    const p = s.cfg.ai_provider;
    _ = g.text(f, label_x, y + @round((row_h - f.cell_h) / 2), "Provider", theme.title_fg);
    const label = p.label();
    const br: Rect = .{ .x = ctl_x, .y = y + @round(row_h * 0.12), .w = @max(Gfx.textWidth(f, label) + 2 * pad, 12 * f.cell_w), .h = @round(row_h * 0.76) };
    s.button(f, theme, br, label, .ai_provider);
    _ = g.text(small, br.x + br.w + @round(10 * s.ui), y + @round((row_h - small.cell_h) / 2), "click to change", theme.dim);
    y += row_h;
    const fw = @min(W - ctl_x - pad, 34 * f.cell_w);
    const rows = [_]struct { t: Config.AiText, label: []const u8 }{
        .{ .t = .model, .label = "Model" },
        .{ .t = .endpoint, .label = "Endpoint" },
        .{ .t = .key, .label = "API key" },
    };
    for (rows) |r| {
        _ = g.text(f, label_x, y + @round((row_h - f.cell_h) / 2), r.label, theme.title_fg);
        const box: Rect = .{ .x = ctl_x, .y = y + @round(row_h * 0.12), .w = fw, .h = @round(row_h * 0.76) };
        var mbuf: [64]u8 = undefined;
        const v = s.cfg.aiText(r.t);
        const shown = if (r.t == .key and v.len > 0) masked(&mbuf, v) else v;
        s.fieldBox(f, theme, box, .{ .ai = r.t }, shown);
        // Empty: what is used instead, dimmed.
        const editing = if (s.edit) |e| std.meta.eql(e.field, Field{ .ai = r.t }) else false;
        if (v.len == 0 and !editing) {
            const ph: []const u8 = switch (r.t) {
                .model => if (p == .off) "" else Ai.defaultModel(p),
                .endpoint => if (p == .off) "" else Ai.defaultEndpoint(p),
                .key => switch (p) {
                    .anthropic => "$ANTHROPIC_API_KEY",
                    .gemini => "$GEMINI_API_KEY",
                    .grok => "$XAI_API_KEY",
                    .openai => "$OPENAI_API_KEY",
                    .ollama => "not needed",
                    .off => "",
                },
            };
            g.clip(box.inset(1));
            _ = g.text(f, box.x + @round(6 * s.ui), box.y + @round((box.h - f.cell_h) / 2), ph, theme.dim.mix(theme.prompt_bg, 0.35));
            g.clip(null);
        }
        y += row_h;
    }
    y += @round(row_h * 0.2);
    y = s.checkRow(f, theme, y, row_h, label_x, ctl_x, "Local memory", s.cfg.ai_memory, .ai_memory);
    const fl = "Forget";
    const fr: Rect = .{ .x = ctl_x + 3 * f.cell_w, .y = y - row_h + @round(row_h * 0.12), .w = Gfx.textWidth(f, fl) + 2 * pad, .h = @round(row_h * 0.76) };
    s.button(f, theme, fr, fl, .ai_forget);
    _ = g.text(small, label_x, y, "folders your shells visit (and their file types), ssh hosts, notes", theme.dim);
    y += @round(small.cell_h * 2);
    const notes = [_][]const u8{
        "With AI on, what you type at the prompt goes to the AI;",
        "gtty's own commands and !cmd still run as typed.",
        "Sent with each request: your request, folder names, the window",
        "list and the memory — never what is inside your files.",
        "Ollama keeps everything on this computer.",
        "Scripts that delete, move, overwrite or send data out are",
        "shown first and ask y/N before they run.",
    };
    for (notes) |n| {
        _ = g.text(small, label_x, y, n, theme.dim);
        y += @round(small.cell_h * 1.35);
    }
}

/// "••••abcd": a key shown by its last 4 characters.
fn masked(buf: []u8, key: []const u8) []const u8 {
    const tail = key[key.len - @min(key.len, 4) ..];
    return std.fmt.bufPrint(buf, "••••••••{s}", .{tail}) catch "••••";
}

/// The part of `p` after $HOME ("/.config/…"), or null.
fn underHome(p: []const u8) ?[]const u8 {
    const home = std.mem.span(c.getenv("HOME") orelse return null);
    if (home.len > 1 and std.mem.startsWith(u8, p, home) and p.len > home.len and p[home.len] == '/') return p[home.len..];
    return null;
}

/// A row's label, wrapped at spaces so it ends before the controls
/// (`ctl_x`); returns the row's height: `row_h`, taller when it wraps.
fn rowLabel(s: *SettingsWindow, f: *Gfx.Face, theme: *const Theme, y: f32, row_h: f32, label_x: f32, ctl_x: f32, label: []const u8) f32 {
    const max_w = ctl_x - label_x - @round(10 * s.ui);
    var lines: [4][]const u8 = undefined;
    var n: usize = 0;
    var rest = std.mem.trim(u8, label, " ");
    while (rest.len > 0) {
        if (n == lines.len - 1 or Gfx.textWidth(f, rest) <= max_w) {
            lines[n] = rest;
            n += 1;
            break;
        }
        // The longest start that fits and ends at a space (a word too
        // long for the column stays whole).
        var cut: ?usize = null;
        var k: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rest, k, ' ')) |sp| : (k = sp + 1) {
            if (cut != null and Gfx.textWidth(f, rest[0..sp]) > max_w) break;
            cut = sp;
        }
        const end = cut orelse rest.len;
        lines[n] = rest[0..end];
        n += 1;
        rest = std.mem.trimStart(u8, rest[end..], " ");
    }
    if (n == 0) return row_h;
    const line_h = @round(f.cell_h * 1.15);
    const block = line_h * @as(f32, @floatFromInt(n - 1)) + f.cell_h;
    const h = @max(row_h, block + (row_h - f.cell_h));
    var ty = y + @round((h - block) / 2);
    for (lines[0..n]) |l| {
        _ = s.gfx.text(f, label_x, ty, l, theme.title_fg);
        ty += line_h;
    }
    return h;
}

fn numRow(s: *SettingsWindow, f: *Gfx.Face, small: *Gfx.Face, theme: *const Theme, y: f32, row_h: f32, label_x: f32, ctl_x: f32, i: usize, label: []const u8, unit: []const u8) f32 {
    const g = &s.gfx;
    const rh = s.rowLabel(f, theme, y, row_h, label_x, ctl_x, label);
    const bh = @round(row_h * 0.76);
    const by = y + @round((rh - bh) / 2);
    const minus: Rect = .{ .x = ctl_x, .y = by, .w = bh, .h = bh };
    s.button(f, theme, minus, "−", .{ .minus = i });
    var vbuf: [32]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{s.cfg.getNum(i)}) catch "";
    const fr: Rect = .{ .x = minus.x + bh + @round(4 * s.ui), .y = by, .w = 9 * f.cell_w, .h = bh };
    s.fieldBox(f, theme, fr, .{ .num = i }, v);
    const plus: Rect = .{ .x = fr.x + fr.w + @round(4 * s.ui), .y = by, .w = bh, .h = bh };
    s.button(f, theme, plus, "+", .{ .plus = i });
    _ = g.text(small, plus.x + bh + @round(10 * s.ui), y + @round((rh - small.cell_h) / 2), unit, theme.dim);
    return y + rh;
}

fn checkRow(s: *SettingsWindow, f: *Gfx.Face, theme: *const Theme, y: f32, row_h: f32, label_x: f32, ctl_x: f32, label: []const u8, on: bool, what: Ctl) f32 {
    const g = &s.gfx;
    const rh = s.rowLabel(f, theme, y, row_h, label_x, ctl_x, label);
    const b = @round(f.cell_h * 1.0);
    const r: Rect = .{ .x = ctl_x, .y = y + @round((rh - b) / 2), .w = b, .h = b };
    g.fill(r, if (on) theme.focus else theme.prompt_bg);
    g.outline(r, if (s.isOver(what)) theme.focus else theme.divider, @max(@round(s.ui), 1));
    if (on) {
        const t = @max(@round(2 * s.ui), 1);
        g.line(r.x + b * 0.22, r.y + b * 0.52, r.x + b * 0.42, r.y + b * 0.72, theme.prompt_bg, t);
        g.line(r.x + b * 0.42, r.y + b * 0.72, r.x + b * 0.78, r.y + b * 0.3, theme.prompt_bg, t);
    }
    s.addCtl(.{ .x = r.x, .y = y, .w = r.w + 2 * f.cell_w, .h = rh }, what);
    return y + rh;
}

fn colorRow(s: *SettingsWindow, f: *Gfx.Face, theme: *const Theme, y: f32, row_h: f32, label_x: f32, ctl_x: f32, i: usize, label: []const u8, sw: f32, fw: f32) f32 {
    const g = &s.gfx;
    const rh = s.rowLabel(f, theme, y, row_h, label_x, ctl_x, label);
    const rgb = s.cfg.colorAt(i);
    const sr: Rect = .{ .x = ctl_x, .y = y + @round((rh - sw) / 2), .w = sw, .h = sw };
    g.fill(sr, rgb);
    g.outline(sr, theme.divider, @max(@round(s.ui), 1));
    var hbuf: [8]u8 = undefined;
    const hex = std.fmt.bufPrint(&hbuf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch "";
    const bh = @round(row_h * 0.76);
    s.fieldBox(f, theme, .{ .x = sr.x + sw + @round(8 * s.ui), .y = y + @round((rh - bh) / 2), .w = fw, .h = bh }, .{ .color = i }, hex);
    return y + rh;
}

/// A text field showing `value`, or what's being typed while it's edited.
fn fieldBox(s: *SettingsWindow, f: *Gfx.Face, theme: *const Theme, r: Rect, field: Field, value: []const u8) void {
    const g = &s.gfx;
    const editing = if (s.edit) |e| std.meta.eql(e.field, field) else false;
    g.fill(r, theme.prompt_bg);
    g.outline(r, if (editing) theme.focus else if (s.isOver(.{ .field = field })) theme.dim else theme.divider, @max(@round(s.ui), 1));
    const p = @round(6 * s.ui);
    const ty = r.y + @round((r.h - f.cell_h) / 2);
    g.clip(r.inset(1));
    defer g.clip(null);
    if (editing) {
        const e = s.edit.?;
        var mbuf: [Config.max_text * 3]u8 = undefined;
        const t = if (field == .ai and field.ai == .key) bullets(&mbuf, e.len) else e.buf[0..e.len];
        // Keep the end (and the cursor) in view.
        const tw = Gfx.textWidth(f, t);
        const x0 = @min(r.x + p, r.x + r.w - p - f.cell_w - tw);
        if (e.fresh and e.len > 0) g.fill(.{ .x = x0, .y = ty, .w = tw, .h = f.cell_h }, theme.selection);
        const end = g.text(f, x0, ty, t, theme.prompt_fg);
        g.fill(.{ .x = end, .y = ty, .w = @max(@round(2 * s.ui), 1), .h = f.cell_h }, theme.cursor);
    } else {
        _ = g.text(f, r.x + p, ty, value, if (value.len == 0) theme.dim else theme.prompt_fg);
        if (value.len == 0 and field == .command) _ = g.text(f, r.x + p, ty, "(none)", theme.dim);
    }
    s.addCtl(r, .{ .field = field });
}

/// `n` bullets (a key being typed is not shown).
fn bullets(buf: []u8, n: usize) []const u8 {
    var k: usize = 0;
    while (k / 3 < n and k + 3 <= buf.len) : (k += 3) @memcpy(buf[k..][0..3], "•");
    return buf[0..k];
}

fn button(s: *SettingsWindow, f: *Gfx.Face, theme: *const Theme, r: Rect, label: []const u8, what: Ctl) void {
    const g = &s.gfx;
    g.fill(r, if (s.isOver(what)) theme.title_bg.mix(theme.focus, 0.3) else theme.title_bg);
    g.outline(r, theme.divider, @max(@round(s.ui), 1));
    _ = g.text(f, r.x + @round((r.w - Gfx.textWidth(f, label)) / 2), r.y + @round((r.h - f.cell_h) / 2), label, theme.title_fg);
    s.addCtl(r, what);
}

/// Script hook: save a screenshot to `path` on the next draw.
pub fn takeShot(s: *SettingsWindow, path: []const u8) void {
    if (s.shot_path) |p| s.gpa.free(p);
    s.shot_path = s.gpa.dupeZ(u8, path) catch null;
    s.dirty = true;
}
