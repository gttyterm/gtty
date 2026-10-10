// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Copying, moving and deleting files in the background (both OSes): files
// dropped on gtty, and the file actions (copy / cut + paste, delete).
#pragma once

// Copy the `n` files / folders `srcs` into folder `dest` (`cp -Rp` each, in
// a child process). A name that exists there gets a number, as Finder's
// "Keep both" does ("notes 2.txt"): nothing is overwritten. A folder
// into itself is skipped. Returns the child's pid, or -1.
int gtty_copy_start(const char *const *srcs, int n, const char *dest);

// Move the `n` files / folders `srcs` into folder `dest`, the same way
// (a free name; a folder not into itself): rename(2), or across disks
// `cp -Rp` then `rm -rf` of the original. Returns the child's pid, or -1.
int gtty_move_start(const char *const *srcs, int n, const char *dest);

// Delete the `n` files / folders `srcs` for good (`rm -rf`, folders with
// everything in them). Returns the child's pid, or -1.
int gtty_remove_start(const char *const *srcs, int n);

// -1: still working; else how many items failed (0: all done). For all
// three.
int gtty_copy_poll(int pid);
