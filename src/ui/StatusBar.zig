// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Status bar: the very small line at the bottom of the dock: the help
//! of the file opener of the window under the mouse (which keys to press)
//! on the left, short
//! notices ("copied 12 lines") on the right, until modals exist. The chips moved into the job windows (a footer strip at
//! the bottom of each window: see JobWindow and Peek.zig), since a chip
//! like git belongs to the folder a window's shell is in, not to gtty.

const Gfx = @import("../render/Gfx.zig");
const color = @import("../core/color.zig");

const Rect = Gfx.Rect;

/// Draw `help` (may be empty) left-aligned and `msg` (a short-lived
/// notice, may be empty) right-aligned in `r`; the notice wins the room.
pub fn draw(gfx: *Gfx, f: *Gfx.Face, r: Rect, help: []const u8, help_color: color.Rgb, msg: []const u8, msg_color: color.Rgb) void {
    const ty = r.y + @round((r.h - f.cell_h) / 2);
    const mw = if (msg.len > 0) Gfx.textWidth(f, msg) else 0;
    if (help.len > 0) {
        const room = r.w - mw - (if (mw > 0) 3 * f.cell_w else 0);
        if (room > 0) {
            gfx.clip(.{ .x = r.x, .y = r.y, .w = room, .h = r.h });
            _ = gfx.text(f, r.x, ty, help, help_color);
            gfx.clip(null);
        }
    }
    if (msg.len == 0) return;
    const mx = @max(r.x + r.w - mw, r.x);
    gfx.clip(r);
    _ = gfx.text(f, mx, ty, msg, msg_color);
    gfx.clip(null);
}
