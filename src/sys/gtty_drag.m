// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: drag a file out of gtty's window (see gtty_drag.h).
#import <Cocoa/Cocoa.h>
#include <SDL3/SDL.h>
#include "gtty_drag.h"

@interface GttyDragSource : NSObject <NSDraggingSource>
@end

static bool active, dropped, dropped_move;
static NSWindow *drag_win;

@implementation GttyDragSource
- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)point
              operation:(NSDragOperation)operation {
    (void)session;
    // Dropped (an operation) on gtty's own window: from one job window to
    // another.
    if (operation != NSDragOperationNone && drag_win != nil && NSPointInRect(point, [drag_win frame])) {
        dropped = true;
        dropped_move = gtty_drag_move_key();
    }
    active = false;
}

// Out of gtty: whatever the target takes (Finder: move on the same disk,
// copy to another, as with a drag from Finder). Inside gtty: copy, or
// generic (what ⌘ leaves: a move, into another job window's folder).
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    if (context == NSDraggingContextWithinApplication) return NSDragOperationCopy | NSDragOperationGeneric;
    return NSDragOperationCopy | NSDragOperationMove | NSDragOperationLink | NSDragOperationGeneric;
}
@end

static GttyDragSource *source;

void gtty_drag_init(void *sdl_window) { (void)sdl_window; }
bool gtty_drag_supported(void) { return true; }
void gtty_drag_tick(void) {}
bool gtty_drag_active(void) { return active; }
bool gtty_drag_take_drop(bool *move) {
    bool d = dropped;
    if (move) *move = dropped_move;
    dropped = false;
    return d;
}
bool gtty_drag_move_key(void) { return ([NSEvent modifierFlags] & NSEventModifierFlagCommand) != 0; }

bool gtty_drag_files(void *sdl_window, const char *const *paths, int n) {
    @autoreleasepool {
        SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
        NSWindow *win = (NSWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        if (win == nil || paths == NULL || n <= 0) return false;
        NSView *view = [win contentView];
        if (source == nil) source = [[GttyDragSource alloc] init];

        // The drag needs the mouse event it starts from: the current one
        // if it is the button / drag, else one made at the mouse.
        NSPoint loc = [win mouseLocationOutsideOfEventStream];
        NSEvent *ev = [NSApp currentEvent];
        if (ev == nil || [ev window] != win ||
            ([ev type] != NSEventTypeLeftMouseDragged && [ev type] != NSEventTypeLeftMouseDown)) {
            ev = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                    location:loc
                               modifierFlags:0
                                   timestamp:[[NSProcessInfo processInfo] systemUptime]
                                windowNumber:[win windowNumber]
                                     context:nil
                                 eventNumber:0
                                  clickCount:1
                                    pressure:1.0];
        }

        // One item per file (its URL and Finder icon), fanned out a little.
        NSPoint at = [view convertPoint:loc fromView:nil];
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:n];
        for (int i = 0; i < n; i++) {
            NSString *p = paths[i] ? [NSString stringWithUTF8String:paths[i]] : nil;
            if (p == nil) continue;
            NSURL *url = [NSURL fileURLWithPath:p];
            NSDraggingItem *item = [[[NSDraggingItem alloc] initWithPasteboardWriter:url] autorelease];
            NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:p];
            [icon setSize:NSMakeSize(48, 48)];
            CGFloat off = 6 * (CGFloat)(i < 5 ? i : 5);
            [item setDraggingFrame:NSMakeRect(at.x - 24 + off, at.y - 24 - off, 48, 48) contents:icon];
            [items addObject:item];
        }
        if ([items count] == 0) return false;
        NSDraggingSession *s = [view beginDraggingSessionWithItems:items event:ev source:source];
        [s setAnimatesToStartingPositionsOnCancelOrFail:YES];
        if (s != nil) {
            active = true;
            dropped = false;
            drag_win = win;
        }
        return s != nil;
    }
}
