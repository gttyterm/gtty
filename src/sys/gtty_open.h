// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef GTTY_OPEN_H
#define GTTY_OPEN_H

/* Opening files with other apps (gtty's `show` command).
 * macOS: LaunchServices. Linux: xdg-mime / mimeinfo.cache, xdg-open, gio. */

typedef struct {
    char id[1024];  /* macOS: the app's bundle path; Linux: its .desktop file */
    char name[256]; /* what the user sees: "TextEdit", "Text Editor" */
    int is_default;
} gtty_app;

/* The default app for a file: its name into `name` (NUL-terminated).
 * 1: found; 0: the file has no default app; -1: can't tell (Linux without
 * xdg-mime: just try `gtty_open_with(path, 0)`). */
int gtty_open_default_app(const char *path, char *name, unsigned long len);

/* The apps that can open a file, the default one first, then by name.
 * Returns how many were written into `out` (at most `max`). */
int gtty_open_apps(const char *path, gtty_app *out, int max);

/* Open a file with app `id` (from gtty_open_apps), or with its default
 * app when `id` is NULL. Doesn't wait for the app. 0: done; -1: failed. */
int gtty_open_with(const char *path, const char *id);

/* Start another gtty (a second OS window, its own process) in folder `cwd`
 * (NULL: gtty's folder): gtty's own executable, no arguments (so it opens
 * a shell). `geometry` (NULL: none): put in its environment as
 * GTTY_WINDOW ("x,y,w,h", where its window goes). Detached; doesn't wait.
 * Its process id: > 0; -1: failed. */
int gtty_open_new_instance(const char *cwd, const char *geometry);

#endif
