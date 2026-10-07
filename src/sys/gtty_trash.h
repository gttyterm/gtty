// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Moving files to the system's trash (the file actions' Move to Trash).
//   macOS: NSFileManager trashItemAtURL (the Finder's Trash, Put Back).
//   Linux: the desktop's trash through `gio trash`, else `trash-put`
//   (trash-cli), else `kioclient6` / `kioclient5 move … trash:/`; none
//   installed, or no desktop session: no trash (the row isn't offered).
#pragma once
#include <stdbool.h>

// This system has a trash gtty can use (asked once, kept).
bool gtty_trash_supported(void);

// Move `path` (absolute) to the trash. 0: done.
int gtty_trash(const char *path);
