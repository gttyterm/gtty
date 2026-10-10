// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef GTTY_APPCHOOSER_H
#define GTTY_APPCHOOSER_H

/* The system's "choose an application" dialog for one file (the file
 * menu's Open With… / Other…).
 * macOS: an open panel in /Applications as a sheet on gtty's window, as
 *   Finder's Open With ▸ Other…: Enable Recommended / All Applications,
 *   Always Open With; gtty opens the file with the app picked.
 * Linux: the desktop portal's app chooser (org.freedesktop.portal.OpenURI
 *   OpenFile with "ask"): GNOME's / KDE's own dialog; the portal opens
 *   the file itself (libgio through dlopen, no headers). */

/* Show it for `path` over SDL window `sdl_window`. 1: shown (the answer
 * comes through gtty_choose_app_take); 0: no such dialog here, or one is
 * already open (`why` says which). */
int gtty_choose_app(void *sdl_window, const char *path, char *why, unsigned long len);

/* The dialog's answer, once:
 *   0  nothing new (still open, or none asked);
 *   1  the file was opened with the app `name`;
 *   2  cancelled;
 *   3  shown by the system, which opens the file itself (Linux);
 *  -1  failed: `name` says why. */
int gtty_choose_app_take(char *name, unsigned long len);

/* App `id`'s icon (a gtty_app id) as `px`×`px` premultiplied RGBA into
 * `rgba` (px * px * 4 bytes). 1: done; 0: none (Linux: not yet). */
int gtty_app_icon(const char *id, int px, unsigned char *rgba);

#endif
