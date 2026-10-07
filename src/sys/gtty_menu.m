// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: gtty's menus in the menu bar SDL creates (gtty app menu with
// About / Preferences… / Services / Hide / Quit, then Window). SDL's
// "Preferences…" row (⌘,, no action) becomes "Settings…" with New Window
// (⌘N), New Shell (⌘T), Run Command and Sync Typing under it; an Edit menu goes between the app menu and Window.
#import <Cocoa/Cocoa.h>
#include <SDL3/SDL.h>
#include "gtty_menu.h"

static uint32_t menu_event;
static gtty_menu_enabled_fn menu_enabled;
static gtty_menu_checked_fn menu_checked;

@interface GttyMenuTarget : NSObject
- (void)pick:(id)sender;
@end

@implementation GttyMenuTarget
- (void)pick:(id)sender {
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = menu_event;
    ev.user.code = (Sint32)[(NSMenuItem *)sender tag];
    SDL_PushEvent(&ev);
}
// A disabled row is dimmed, and its key goes on to gtty as a plain key.
// A checked row (Sync Typing while on) gets a check mark.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (menu_checked) [item setState:menu_checked((int)[item tag]) ? NSControlStateValueOn : NSControlStateValueOff];
    return menu_enabled ? menu_enabled((int)[item tag]) : YES;
}
@end

static GttyMenuTarget *target;

static NSMenuItem *item(NSString *title, int code, NSString *key) {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:@selector(pick:) keyEquivalent:key];
    [it setTarget:target];
    [it setTag:code];
    return it;
}

// A top-level menu inserted into the menu bar at `at`.
static NSMenu *topMenu(NSMenu *bar, NSString *title, NSInteger at) {
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    [top setSubmenu:m];
    [bar insertItem:top atIndex:at];
    return m;
}

bool gtty_menu_install(uint32_t event_type, gtty_menu_enabled_fn enabled, gtty_menu_checked_fn checked) {
    @autoreleasepool {
        NSMenu *bar = [NSApp mainMenu];
        if (bar == nil || [bar numberOfItems] == 0) return false;
        NSMenu *app = [[bar itemAtIndex:0] submenu];
        if (app == nil) return false;
        menu_event = event_type;
        menu_enabled = enabled;
        menu_checked = checked;
        target = [[GttyMenuTarget alloc] init];

        // About gtty: gtty's own box (version, copyright, license, source)
        // instead of the standard panel.
        for (NSInteger i = 0; i < [app numberOfItems]; i++) {
            NSMenuItem *it = [app itemAtIndex:i];
            if ([it action] == @selector(orderFrontStandardAboutPanel:)) {
                [it setTarget:target];
                [it setAction:@selector(pick:)];
                [it setTag:GTTY_MENU_ABOUT];
                break;
            }
        }

        // gtty ▸ Settings… (where SDL's Preferences… row is), Run Command.
        NSInteger at = 1;
        for (NSInteger i = 0; i < [app numberOfItems]; i++) {
            if ([[[app itemAtIndex:i] keyEquivalent] isEqualToString:@","]) {
                at = i;
                [app removeItemAtIndex:i];
                break;
            }
        }
        [app insertItem:item(@"Settings…", GTTY_MENU_SETTINGS, @",") atIndex:at];
        [app insertItem:item(@"New Window", GTTY_MENU_NEW_WINDOW, @"n") atIndex:at + 1];
        [app insertItem:item(@"New Shell", GTTY_MENU_NEW_SHELL, @"t") atIndex:at + 2];
        [app insertItem:item(@"Run Command", GTTY_MENU_RUN, @"") atIndex:at + 3];
        [app insertItem:item(@"Sync Typing", GTTY_MENU_SYNC_TYPING, @"") atIndex:at + 4];

        // Edit, after the app menu.
        NSMenu *edit = topMenu(bar, @"Edit", 1);
        [edit addItem:item(@"Copy", GTTY_MENU_COPY, @"c")];
        [edit addItem:item(@"Paste", GTTY_MENU_PASTE, @"v")];
        [edit addItem:[NSMenuItem separatorItem]];
        [edit addItem:item(@"Select All", GTTY_MENU_SELECT_ALL, @"a")];
        return true;
    }
}

bool gtty_app_yield_to(int pid) {
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
        if (app == nil) return false;
        if (@available(macOS 14.0, *)) [NSApp yieldActivationToApplication:app];
        return true;
    }
}

bool gtty_app_activate(void) {
    if ([NSApp isActive]) return true;
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    return [NSApp isActive];
}
