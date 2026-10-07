// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Drag and drop of files between gtty and other apps.
//
// Out of gtty (a held file name, a files window row): as if dragged from
// the file manager; the drop target decides copy / move / link.
//   macOS: NSDraggingSession from the window's content view.
//   Linux: Wayland only (wl_data_device): gtty's own wl_pointer on SDL's
//   connection, on a private event queue, gives the serial of the button
//   press that start_drag needs (SDL keeps its own). libwayland-client is
//   loaded at run time. Under X11 drag and drop is off.
// Into gtty: SDL's drop events (App), only where
// gtty_drag_supported(). From one job window to another: gtty's own drag
// dropped on its own window (gtty_drag_take_drop).
#pragma once
#include <stdbool.h>

// Once, after gtty's first window exists (Wayland: connect to SDL's
// display, find the seat and the data device manager).
void gtty_drag_init(void *sdl_window);

// Drag and drop works here (macOS; Linux under Wayland).
bool gtty_drag_supported(void);

// Each frame (Wayland: gtty's own events: the press serial, the drag
// source's requests).
void gtty_drag_tick(void);

// Start dragging the `n` files `paths` (absolute) together from SDL window
// `sdl_window`; the left button must be down. False: nothing started.
bool gtty_drag_files(void *sdl_window, const char *const *paths, int n);

// A drag started by gtty is still going (App takes its drops on gtty
// from what it dragged, not from SDL's drop data).
bool gtty_drag_active(void);

// The last drag gtty started was dropped on gtty's own window (once:
// cleared by the call). macOS: the session ended with an operation inside
// the window; Wayland: gtty's data device saw the drop. `move`: the move
// key (gtty_drag_move_key) was held at the drop.
bool gtty_drag_take_drop(bool *move);

// The key that makes a drop between job windows a move is held now
// (macOS ⌘, read from the system: SDL's state doesn't follow keys during
// a drag; Linux Shift, the usual drag-and-drop move key there).
bool gtty_drag_move_key(void);
