// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! gtty's settings, as the settings window edits them, saved in a small
//! text file: `$GTTY_CONFIG`, else `$XDG_CONFIG_HOME/gtty/config`, else
//! `~/.config/gtty/config`. One `key = value` per line, `#` comments.
//! Unknown keys and bad values are skipped (the default stays); the file is
//! rewritten whole on every change.
//!
//! Command-line options and environment variables (`GTTY_FONT_SIZE`, …)
//! win over the file for that run; the file keeps what the user set in the
//! settings window.

const std = @import("std");
const c = @import("../c.zig").c;
const color = @import("color.zig");
const Rgb = color.Rgb;
const Screen = @import("Screen.zig");

const Config = @This();

pub const max_command = 256;
/// Longest text setting.
pub const max_text = 256;

/// A text setting kept in the struct (no allocation).
pub fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn get(s: *const @This()) []const u8 {
            return s.buf[0..s.len];
        }
        pub fn set(s: *@This(), v: []const u8) void {
            const k = @min(v.len, n);
            @memcpy(s.buf[0..k], v[0..k]);
            s.len = k;
        }
    };
}

/// Where AI requests go; `off`: no AI (the prompt works as without it).
pub const AiProvider = enum {
    off,
    anthropic,
    /// Google Gemini, through its OpenAI-compatible endpoint.
    gemini,
    /// xAI Grok (OpenAI-compatible).
    grok,
    /// Any OpenAI-compatible API (OpenAI, Mistral, Groq, OpenRouter, a
    /// local server, …).
    openai,
    ollama,

    pub const names = [_][]const u8{ "off", "anthropic", "gemini", "grok", "openai", "ollama" };
    pub const labels = [_][]const u8{ "Off", "Anthropic (Claude)", "Google Gemini", "xAI Grok", "OpenAI-compatible", "Ollama (local)" };

    pub fn name(p: AiProvider) []const u8 {
        return names[@intFromEnum(p)];
    }
    pub fn label(p: AiProvider) []const u8 {
        return labels[@intFromEnum(p)];
    }
    pub fn parse(s: []const u8) ?AiProvider {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }
};

/// The AI's text settings, by key (the settings window's fields).
pub const AiText = enum { model, endpoint, key };
pub const ai_text_keys = [_][]const u8{ "ai-model", "ai-endpoint", "ai-key" };

font_pt: f32 = 13,
scrollback: usize = Screen.default_max_lines,
/// The start-up command (`-c`): "s" = the user's shell, "" = none.
command_buf: [max_command]u8 = [_]u8{'s'} ++ [_]u8{0} ** (max_command - 1),
command_len: usize = 1,
/// New job windows start with colors on.
colors: bool = true,
anim_ms: u64 = 220,
tip_ms: u64 = 500,
chip_hover_ms: u64 = 500,
peek_close_ms: u64 = 5000,
kill_grace_ms: u64 = 2000,
fg: Rgb = (color.Theme{}).fg,
bg: Rgb = (color.Theme{}).bg,
palette: [16]Rgb = (color.Theme{}).palette,
/// Left-edge marks (typed / AI rows): shown, width in px, colors.
marks: bool = true,
mark_width: u64 = 4,
mark_input: Rgb = (color.Theme{}).mark_input,
mark_ai: Rgb = (color.Theme{}).mark_ai,
/// File and folder names in job windows: outlined on hover, double-click
/// opens, hold and drag drags the file out.
file_opener: bool = true,
/// Folder names in output that has no colors of its own: drawn in the
/// focus blue.
color_folders: bool = true,
/// After a file action done in gtty: run the shell's last listing
/// command again.
refresh_ls: bool = true,
/// The last shell window closed or exited (and no other job running):
/// gtty quits instead of opening a new shell.
quit_on_last_shell: bool = true,
/// AI at the prompt (src/ai/): provider, model, endpoint (empty: the
/// provider's), API key (empty: $ANTHROPIC_API_KEY / $OPENAI_API_KEY),
/// the user's extra instructions, and the local memory on / off.
ai_provider: AiProvider = .off,
ai_model: Str(128) = .{},
ai_endpoint: Str(256) = .{},
ai_key: Str(256) = .{},
ai_memory: bool = true,

pub fn aiText(cfg: *Config, t: AiText) []const u8 {
    return switch (t) {
        .model => cfg.ai_model.get(),
        .endpoint => cfg.ai_endpoint.get(),
        .key => cfg.ai_key.get(),
    };
}

pub fn setAiText(cfg: *Config, t: AiText, v: []const u8) void {
    switch (t) {
        .model => cfg.ai_model.set(v),
        .endpoint => cfg.ai_endpoint.set(v),
        .key => cfg.ai_key.set(v),
    }
}

pub fn command(cfg: *const Config) []const u8 {
    return cfg.command_buf[0..cfg.command_len];
}

pub fn setCommand(cfg: *Config, s: []const u8) void {
    const n = @min(s.len, max_command);
    @memcpy(cfg.command_buf[0..n], s[0..n]);
    cfg.command_len = n;
}

/// A number setting: its key, its field, and the range the settings
/// window and the parser keep it in.
pub const Num = struct {
    key: []const u8,
    field: enum { font_pt, scrollback, anim_ms, tip_ms, chip_hover_ms, peek_close_ms, kill_grace_ms, mark_width },
    min: f64,
    max: f64,
    step: f64,
};

pub const nums = [_]Num{
    .{ .key = "font-size", .field = .font_pt, .min = 8, .max = 40, .step = 1 },
    .{ .key = "scrollback", .field = .scrollback, .min = 1000, .max = 1_000_000, .step = 1000 },
    .{ .key = "anim-ms", .field = .anim_ms, .min = 0, .max = 2000, .step = 20 },
    .{ .key = "tooltip-ms", .field = .tip_ms, .min = 0, .max = 3000, .step = 100 },
    .{ .key = "chip-hover-ms", .field = .chip_hover_ms, .min = 0, .max = 3000, .step = 100 },
    .{ .key = "peek-close-ms", .field = .peek_close_ms, .min = 1000, .max = 60_000, .step = 500 },
    .{ .key = "kill-grace-ms", .field = .kill_grace_ms, .min = 500, .max = 10_000, .step = 500 },
    .{ .key = "mark-width", .field = .mark_width, .min = 1, .max = 8, .step = 1 },
};

pub fn numIndex(key: []const u8) ?usize {
    for (nums, 0..) |n, i| if (std.mem.eql(u8, n.key, key)) return i;
    return null;
}

pub fn getNum(cfg: *const Config, i: usize) f64 {
    return switch (nums[i].field) {
        .font_pt => cfg.font_pt,
        .scrollback => @floatFromInt(cfg.scrollback),
        .anim_ms => @floatFromInt(cfg.anim_ms),
        .tip_ms => @floatFromInt(cfg.tip_ms),
        .chip_hover_ms => @floatFromInt(cfg.chip_hover_ms),
        .peek_close_ms => @floatFromInt(cfg.peek_close_ms),
        .kill_grace_ms => @floatFromInt(cfg.kill_grace_ms),
        .mark_width => @floatFromInt(cfg.mark_width),
    };
}

/// Set a number, clamped to its range.
pub fn setNum(cfg: *Config, i: usize, v_in: f64) void {
    const n = nums[i];
    const v = std.math.clamp(@round(v_in), n.min, n.max);
    const u: u64 = @intFromFloat(v);
    switch (n.field) {
        .font_pt => cfg.font_pt = @floatCast(v),
        .scrollback => cfg.scrollback = u,
        .anim_ms => cfg.anim_ms = u,
        .tip_ms => cfg.tip_ms = u,
        .chip_hover_ms => cfg.chip_hover_ms = u,
        .peek_close_ms => cfg.peek_close_ms = u,
        .kill_grace_ms => cfg.kill_grace_ms = u,
        .mark_width => cfg.mark_width = u,
    }
}

/// The colors the settings window edits: text, background, the 16 ANSI
/// colors, then the two left-edge mark colors (`mark_color_first`).
pub const color_keys = [_][]const u8{ "fg", "bg" } ++ ansiKeys() ++ [_][]const u8{ "mark-input", "mark-ai" };
pub const mark_color_first = 18;

fn ansiKeys() [16][]const u8 {
    var k: [16][]const u8 = undefined;
    for (&k, 0..) |*s, i| s.* = std.fmt.comptimePrint("color{d}", .{i});
    return k;
}

pub fn colorPtr(cfg: *Config, i: usize) *Rgb {
    return switch (i) {
        0 => &cfg.fg,
        1 => &cfg.bg,
        18 => &cfg.mark_input,
        19 => &cfg.mark_ai,
        else => &cfg.palette[i - 2],
    };
}

pub fn colorAt(cfg: *const Config, i: usize) Rgb {
    return @constCast(cfg).colorPtr(i).*;
}

/// "#rrggbb" or "rrggbb".
pub fn parseRgb(s_in: []const u8) ?Rgb {
    const s = if (std.mem.startsWith(u8, s_in, "#")) s_in[1..] else s_in;
    if (s.len != 6) return null;
    const v = std.fmt.parseInt(u24, s, 16) catch return null;
    return .{ .r = @intCast(v >> 16), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
}

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false")) return false;
    return null;
}

/// Apply one line of the file (comments, blanks and bad lines: nothing).
pub fn parseLine(cfg: *Config, line_in: []const u8) void {
    const line = std.mem.trim(u8, line_in, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0) return;
    if (std.mem.eql(u8, key, "command")) {
        // Quotes keep leading / trailing spaces and say "" = none.
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        cfg.setCommand(val);
    } else if (std.mem.eql(u8, key, "colors")) {
        if (parseBool(val)) |b| cfg.colors = b;
    } else if (std.mem.eql(u8, key, "marks")) {
        if (parseBool(val)) |b| cfg.marks = b;
    } else if (std.mem.eql(u8, key, "ai")) {
        if (AiProvider.parse(val)) |p| cfg.ai_provider = p;
    } else if (std.mem.eql(u8, key, "ai-memory")) {
        if (parseBool(val)) |b| cfg.ai_memory = b;
    } else if (aiTextKey(key)) |t| {
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        cfg.setAiText(t, val);
    } else if (numIndex(key)) |i| {
        const v = std.fmt.parseFloat(f64, val) catch return;
        cfg.setNum(i, v);
    } else if (std.mem.eql(u8, key, "file-opener") or std.mem.eql(u8, key, "sub.file-opener")) {
        // sub.file-opener: its name from when it was a subscriber.
        if (parseBool(val)) |b| cfg.file_opener = b;
    } else if (std.mem.eql(u8, key, "refresh-ls")) {
        if (parseBool(val)) |b| cfg.refresh_ls = b;
    } else if (std.mem.eql(u8, key, "color-folders")) {
        if (parseBool(val)) |b| cfg.color_folders = b;
    } else if (std.mem.eql(u8, key, "quit-on-last-shell")) {
        if (parseBool(val)) |b| cfg.quit_on_last_shell = b;
    } else {
        for (color_keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            if (parseRgb(val)) |rgb| cfg.colorPtr(i).* = rgb;
            return;
        };
    }
}

fn aiTextKey(key: []const u8) ?AiText {
    for (ai_text_keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return @enumFromInt(i);
    return null;
}

pub fn parse(text: []const u8) Config {
    var cfg: Config = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| cfg.parseLine(line);
    return cfg;
}

/// The whole file.
pub fn format(cfg: *const Config, w: *std.Io.Writer) !void {
    try w.writeAll("# gtty settings (written by the settings window; edits by hand are kept\n# if they are valid). Command-line options and GTTY_* variables win.\n\n");
    for (nums, 0..) |n, i| {
        const v = cfg.getNum(i);
        try w.print("{s} = {d}\n", .{ n.key, v });
    }
    try w.print("command = \"{s}\"\n", .{cfg.command()});
    try w.print("colors = {s}\n", .{if (cfg.colors) "on" else "off"});
    try w.print("marks = {s}\n", .{if (cfg.marks) "on" else "off"});
    try w.print("file-opener = {s}\n", .{if (cfg.file_opener) "on" else "off"});
    try w.print("color-folders = {s}\n", .{if (cfg.color_folders) "on" else "off"});
    try w.print("refresh-ls = {s}\n", .{if (cfg.refresh_ls) "on" else "off"});
    try w.print("quit-on-last-shell = {s}\n\n", .{if (cfg.quit_on_last_shell) "on" else "off"});
    for (color_keys, 0..) |k, i| {
        const rgb = cfg.colorAt(i);
        try w.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{ k, rgb.r, rgb.g, rgb.b });
    }
    try w.writeAll("\n");
    try w.print("ai = {s}\n", .{cfg.ai_provider.name()});
    for (ai_text_keys, 0..) |k, i| try w.print("{s} = \"{s}\"\n", .{ k, @constCast(cfg).aiText(@enumFromInt(i)) });
    try w.print("ai-memory = {s}\n", .{if (cfg.ai_memory) "on" else "off"});
}

/// Where the file is ($GTTY_CONFIG, XDG, ~/.config); null: no home.
pub fn path(buf: []u8) ?[:0]const u8 {
    if (c.getenv("GTTY_CONFIG")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (c.getenv("XDG_CONFIG_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrintSentinel(buf, "{s}/gtty/config", .{std.mem.span(x)}, 0) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/gtty/config", .{std.mem.span(home)}, 0) catch null;
}

/// Read the file (missing or unreadable: the defaults).
pub fn load() Config {
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return .{};
    const fp = c.fopen(p.ptr, "r") orelse return .{};
    defer _ = c.fclose(fp);
    var cfg: Config = .{};
    var buf: [max_text + 64]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) cfg.parseLine(std.mem.sliceTo(&buf, 0));
    return cfg;
}

/// Write the file (creating its folder). False when it couldn't.
pub fn save(cfg: *const Config) bool {
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return false;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirs(p[0..slash]);
    var out: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    cfg.format(&w) catch return false;
    // Write a temp file next to it, then rename: never a half-written file.
    var tbuf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.tmp", .{p}, 0) catch return false;
    const fp = c.fopen(tmp.ptr, "w") orelse return false;
    // Only the user can read it (it may hold an API key).
    _ = c.chmod(tmp.ptr, 0o600);
    const data = w.buffered();
    const ok = c.fwrite(data.ptr, 1, data.len, fp) == data.len;
    if (c.fclose(fp) != 0 or !ok) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    return c.rename(tmp.ptr, p.ptr) == 0;
}

/// mkdir -p (each missing parent, 0700 like ~/.config).
fn mkdirs(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = c.mkdir(z.ptr, 0o700);
        }
    }
}

test "config: parse, clamp, skip bad lines, round trip" {
    const t = std.testing;
    var cfg = parse(
        \\# comment
        \\font-size = 15
        \\scrollback = 5
        \\anim-ms = abc
        \\command = "htop -d 5"
        \\colors = off
        \\fg = #112233
        \\color1 = ff0000
        \\color2 = #12
        \\sub.file-opener = off
        \\sub.nope = off
        \\marks = off
        \\quit-on-last-shell = off
        \\mark-input = #00ff00
        \\ai = anthropic
        \\ai-model = "claude-x"
        \\ai-instructions = say "hi" first
        \\ai-endpoint = "http://h/v1"
        \\ai = bogus
        \\nonsense
    );
    try t.expectEqual(AiProvider.anthropic, cfg.ai_provider);
    try t.expectEqualStrings("claude-x", cfg.ai_model.get());
    try t.expectEqualStrings("http://h/v1", cfg.ai_endpoint.get()); // ai-instructions: no such setting
    try t.expect(!cfg.marks);
    try t.expect(cfg.mark_input.eql(Rgb.hex(0x00ff00)));
    try t.expectEqual(@as(f32, 15), cfg.font_pt);
    try t.expectEqual(@as(usize, 1000), cfg.scrollback); // clamped
    try t.expectEqual(@as(u64, 220), cfg.anim_ms); // bad value: default
    try t.expectEqualStrings("htop -d 5", cfg.command());
    try t.expect(!cfg.colors);
    try t.expect(cfg.fg.eql(Rgb.hex(0x112233)));
    try t.expect(cfg.palette[1].eql(Rgb.hex(0xff0000)));
    try t.expect(cfg.palette[2].eql((color.Theme{}).palette[2]));
    try t.expect(!cfg.file_opener);
    try t.expect(!cfg.quit_on_last_shell);

    cfg.setCommand("");
    var out: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try cfg.format(&w);
    const back = parse(w.buffered());
    try t.expectEqualStrings("", back.command());
    try t.expectEqual(cfg.font_pt, back.font_pt);
    try t.expectEqual(cfg.scrollback, back.scrollback);
    try t.expect(back.fg.eql(cfg.fg));
    try t.expect(!back.file_opener);
    try t.expect(!back.colors);
    try t.expect(!back.marks);
    try t.expect(!back.quit_on_last_shell);
    try t.expect(back.mark_input.eql(Rgb.hex(0x00ff00)));
    try t.expectEqual(AiProvider.anthropic, back.ai_provider);
    try t.expectEqualStrings("claude-x", back.ai_model.get());
    try t.expectEqualStrings("http://h/v1", back.ai_endpoint.get());
    try t.expect(std.mem.indexOf(u8, w.buffered(), "instructions") == null);
}
