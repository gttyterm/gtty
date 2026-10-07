// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Copying dropped files into a folder, in the background (both OSes).
#pragma once

// Copy the `n` files / folders `srcs` into folder `dest` (`cp -Rp` each, in
// a child process). A name that exists there gets a number, as Finder's
// "Keep both" does ("notes 2.txt"): nothing is overwritten. A folder
// into itself is skipped. Returns the child's pid, or -1.
int gtty_copy_start(const char *const *srcs, int n, const char *dest);

// -1: still copying; else how many items failed (0: all copied).
int gtty_copy_poll(int pid);
