// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Colors are stored the way the program sent them (default / palette
//! index / truecolor) and only turned into real RGB at draw time. That is
//! what lets gtty re-theme old output and fix unreadable contrast later.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hex(comptime v: u24) Rgb {
        return .{ .r = @intCast(v >> 16), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
    }

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        const f = struct {
            fn ch(x: u8, y: u8, k: f32) u8 {
                const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
                return @intFromFloat(std.math.clamp(@round(v), 0, 255));
            }
        };
        return .{ .r = f.ch(a.r, b.r, t), .g = f.ch(a.g, b.g, t), .b = f.ch(a.b, b.b, t) };
    }

    fn lin(c: u8) f32 {
        const s = @as(f32, @floatFromInt(c)) / 255.0;
        return if (s <= 0.03928) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
    }

    pub fn luminance(c: Rgb) f32 {
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    pub fn contrast(a: Rgb, b: Rgb) f32 {
        const la = a.luminance();
        const lb = b.luminance();
        return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
    }
};

pub const Color = struct {
    tag: Tag = .default,
    v: [3]u8 = .{ 0, 0, 0 },

    pub const Tag = enum(u8) { default, indexed, rgb };

    pub fn indexed(i: u8) Color {
        return .{ .tag = .indexed, .v = .{ i, 0, 0 } };
    }
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .tag = .rgb, .v = .{ r, g, b } };
    }
    pub fn eql(a: Color, b: Color) bool {
        return a.tag == b.tag and std.mem.eql(u8, &a.v, &b.v);
    }
};

pub const Theme = struct {
    // Terminal content
    fg: Rgb = Rgb.hex(0xd7dae0),
    bg: Rgb = Rgb.hex(0x161a21),
    /// The 16 ANSI colors: xterm's default table (the colors programs
    /// were written against, on a black background). 0–7 normal, 8–15
    /// bright; 16–255 are the fixed xterm cube and gray ramp (`index`).
    palette: [16]Rgb = .{
        Rgb.hex(0x000000), Rgb.hex(0xcd0000), Rgb.hex(0x00cd00), Rgb.hex(0xcdcd00),
        Rgb.hex(0x0000ee), Rgb.hex(0xcd00cd), Rgb.hex(0x00cdcd), Rgb.hex(0xe5e5e5),
        Rgb.hex(0x7f7f7f), Rgb.hex(0xff0000), Rgb.hex(0x00ff00), Rgb.hex(0xffff00),
        Rgb.hex(0x5c5cff), Rgb.hex(0xff00ff), Rgb.hex(0x00ffff), Rgb.hex(0xffffff),
    },
    // Chrome
    desktop: Rgb = Rgb.hex(0x0e1014),
    title_bg: Rgb = Rgb.hex(0x2b313b), // lighter than the body (bg)
    title_fg: Rgb = Rgb.hex(0xc9ced6),
    border: Rgb = Rgb.hex(0x2a313c),
    divider: Rgb = Rgb.hex(0x3d4553),
    focus: Rgb = Rgb.hex(0x5aa9ff),
    stderr_accent: Rgb = Rgb.hex(0xff6b6b),
    stderr_bg: Rgb = Rgb.hex(0x1d1618),
    ok: Rgb = Rgb.hex(0x98c379),
    dim: Rgb = Rgb.hex(0x8c95a3),
    prompt_bg: Rgb = Rgb.hex(0x12151b),
    prompt_fg: Rgb = Rgb.hex(0xe6e9ef),
    cursor: Rgb = Rgb.hex(0x5aa9ff),
    selection: Rgb = Rgb.hex(0x2e4a6b),
    /// Left-edge marks of a job window's rows: what the user typed, the
    /// output, and anything AI-related.
    mark_input: Rgb = Rgb.hex(0x25d366),
    mark_ai: Rgb = Rgb.hex(0xa970ff),
    /// Sync typing: the frame of a read-only window that gets the source
    /// window's typing (purple-red).
    sync: Rgb = Rgb.hex(0xd0459a),

    /// Minimum WCAG-style contrast ratio between text and its background.
    min_contrast: f32 = 3.0,

    pub fn resolve(t: *const Theme, c: Color, is_fg: bool) Rgb {
        return t.resolveBold(c, is_fg, false);
    }

    /// Like `resolve`; `bold` text in one of the 8 normal colors gets its
    /// bright version, as in xterm (gtty has no bold face yet).
    pub fn resolveBold(t: *const Theme, c: Color, is_fg: bool, bold: bool) Rgb {
        if (bold and is_fg and c.tag == .indexed and c.v[0] < 8) return t.palette[c.v[0] + 8];
        return switch (c.tag) {
            .default => if (is_fg) t.fg else t.bg,
            .rgb => .{ .r = c.v[0], .g = c.v[1], .b = c.v[2] },
            .indexed => t.index(c.v[0]),
        };
    }

    pub fn index(t: *const Theme, i: u8) Rgb {
        if (i < 16) return t.palette[i];
        if (i < 232) {
            const n = i - 16;
            const steps = [_]u8{ 0, 95, 135, 175, 215, 255 };
            return .{ .r = steps[n / 36], .g = steps[(n / 6) % 6], .b = steps[n % 6] };
        }
        const g: u8 = 8 + (i - 232) * 10;
        return .{ .r = g, .g = g, .b = g };
    }

    /// Smart colors: nudge the foreground toward white or black until it
    /// is readable on `bg`. Programs that assume a light theme stay legible.
    pub fn readable(t: *const Theme, fg: Rgb, bg: Rgb) Rgb {
        if (fg.contrast(bg) >= t.min_contrast) return fg;
        const toward = if (bg.luminance() < 0.4) Rgb.hex(0xffffff) else Rgb.hex(0x000000);
        var k: f32 = 0.15;
        while (k < 1.0) : (k += 0.15) {
            const c = fg.mix(toward, k);
            if (c.contrast(bg) >= t.min_contrast) return c;
        }
        return toward;
    }
};

test "contrast fix makes dark blue readable on dark bg" {
    const t = Theme{};
    const fixed = t.readable(Rgb.hex(0x000080), t.bg);
    try std.testing.expect(fixed.contrast(t.bg) >= t.min_contrast);
}

test "bold makes the 8 normal colors bright" {
    const t = Theme{};
    try std.testing.expect(t.resolveBold(Color.indexed(1), true, true).eql(t.palette[9]));
    try std.testing.expect(t.resolveBold(Color.indexed(1), false, true).eql(t.palette[1]));
    try std.testing.expect(t.resolveBold(Color.indexed(9), true, true).eql(t.palette[9]));
}

test "xterm 256 palette" {
    const t = Theme{};
    try std.testing.expect(t.index(196).eql(Rgb.hex(0xff0000)));
    try std.testing.expect(t.index(232).eql(Rgb.hex(0x080808)));
}
