// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// No global menu bar (Linux): gtty draws its own menu bar instead.
#include "gtty_menu.h"

bool gtty_app_yield_to(int pid) {
    (void)pid;
    return true;
}
bool gtty_app_activate(void) { return true; }

bool gtty_menu_install(uint32_t event_type, gtty_menu_enabled_fn enabled, gtty_menu_checked_fn checked) {
    (void)event_type;
    (void)enabled;
    (void)checked;
    return false;
}
