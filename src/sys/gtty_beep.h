// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef GTTY_BEEP_H
#define GTTY_BEEP_H

/* Play the system's error/alert sound. Returns 1 if the platform has one
 * (macOS: the user's alert sound), 0 if the caller should make its own. */
int gtty_beep(void);

#endif
