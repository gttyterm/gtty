// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: the Trash (see gtty_trash.h).
#import <Foundation/Foundation.h>
#include "gtty_trash.h"

bool gtty_trash_supported(void) { return true; }

int gtty_trash(const char *path) {
    @autoreleasepool {
        if (path == NULL) return -1;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        NSError *err = nil;
        return [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:&err] ? 0 : -1;
    }
}
