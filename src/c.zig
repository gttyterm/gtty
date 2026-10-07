// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! All C imports in one place, so every file sees the same types.
pub const c = @cImport({
    // glibc fortify macros do not translate to Zig in release builds.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("gtty_pty.h");
    @cInclude("gtty_beep.h");
    @cInclude("gtty_open.h");
    @cInclude("gtty_menu.h");
    @cInclude("gtty_drag.h");
    @cInclude("gtty_copy.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("time.h");
    @cInclude("signal.h");
});
