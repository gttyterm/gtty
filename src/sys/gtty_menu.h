// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// gtty's menus in the OS's own menu bar (macOS): the app menu "gtty"
// (Settings…, Run Command, Sync Typing, next to About / Hide / Quit); it
// also has New Window (⌘N, another gtty) and New Shell (⌘T, like a new
// tab). The Dock icon's menu has New Window too. No Edit menu (removed 2026-10-07: with several job windows its
// Copy / Paste read as "which window?"; ⌘C / ⌘V / ⌘A are plain keys in
// gtty, acting on the window the mouse or keyboard is in).
// Elsewhere there is no global menu bar: gtty_menu_install returns false
// and gtty draws a bar of its own.
//
// A pick arrives as an SDL event of the type given to gtty_menu_install,
// with `user.code` = one of the codes below. Whether a row is enabled is asked from `enabled(code)` when the
// menu opens or its key is pressed.
#pragma once
#include <stdbool.h>
#include <stdint.h>

enum {
    GTTY_MENU_RUN = 1,        // Run Command: keyboard to the prompt
    GTTY_MENU_SETTINGS = 2,   // Settings…
    // 3, 4, 5: the old Edit menu's Copy, Paste, Select All (gone).
    GTTY_MENU_NEW_SHELL = 6,  // gtty ▸ New Shell (⌘T)
    GTTY_MENU_NEW_WINDOW = 7, // gtty ▸ New Window (⌘N): another gtty
    GTTY_MENU_SYNC_TYPING = 8, // gtty ▸ Sync Typing (checked while on)
    GTTY_MENU_ABOUT = 9,      // gtty ▸ About gtty (gtty's own About box)
};

typedef bool (*gtty_menu_enabled_fn)(int code);
// Whether a row shows a check mark (asked with `enabled`).
typedef bool (*gtty_menu_checked_fn)(int code);

// New Window: bringing the new gtty to the front (macOS 14+ only lets an
// app come to the front when the app in front yields to it). The old gtty
// yields to process `pid` (true: done; false: that process isn't known to
// the system yet, try again); the new one asks to be the active app (true:
// it is). Elsewhere: nothing to do (true).
bool gtty_app_yield_to(int pid);
bool gtty_app_activate(void);

// Add gtty's menus to the native menu bar (after SDL_Init). False: none.
bool gtty_menu_install(uint32_t event_type, gtty_menu_enabled_fn enabled, gtty_menu_checked_fn checked);
