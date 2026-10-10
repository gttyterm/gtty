// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: choose the app that opens a file (see gtty_appchooser.h), as
// Finder's Open With ▸ Other…
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <SDL3/SDL.h>
#include "gtty_appchooser.h"
#include "gtty_open.h"

static bool busy;
static int result;
static char result_text[512];

static void set_result(int r, NSString *text) {
    result = r;
    result_text[0] = 0;
    if (text) [text getCString:result_text maxLength:sizeof result_text encoding:NSUTF8StringEncoding];
}

@interface GttyAppChooser : NSObject <NSOpenSavePanelDelegate>
@property(strong) NSOpenPanel *panel;
@property(strong) NSURL *file;
@property(strong) NSSet<NSString *> *recommended;
@property(strong) NSButton *always;
@property BOOL all;
@end

@implementation GttyAppChooser
// Recommended: only the apps that say they open this kind of file
// (folders stay enabled to look inside).
- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url {
    (void)sender;
    if (self.all || ![[url pathExtension] isEqualToString:@"app"]) return YES;
    return [self.recommended containsObject:[[url URLByResolvingSymlinksInPath] path]];
}

- (void)enableChanged:(NSPopUpButton *)pop {
    self.all = [pop indexOfSelectedItem] == 1;
    [self.panel validateVisibleColumns];
}

- (NSView *)accessory {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 64)];
    NSTextField *label = [NSTextField labelWithString:@"Enable:"];
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [pop addItemsWithTitles:@[ @"Recommended Applications", @"All Applications" ]];
    [pop selectItemAtIndex:self.all ? 1 : 0];
    [pop setTarget:self];
    [pop setAction:@selector(enableChanged:)];
    [pop sizeToFit];
    self.always = [NSButton checkboxWithTitle:@"Always Open With" target:nil action:nil];
    [label sizeToFit];
    [self.always sizeToFit];
    CGFloat w = label.frame.size.width + 8 + pop.frame.size.width;
    CGFloat x = (v.frame.size.width - w) / 2;
    [label setFrameOrigin:NSMakePoint(x, 36 + (pop.frame.size.height - label.frame.size.height) / 2)];
    [pop setFrameOrigin:NSMakePoint(x + label.frame.size.width + 8, 36)];
    [self.always setFrameOrigin:NSMakePoint((v.frame.size.width - self.always.frame.size.width) / 2, 8)];
    [v addSubview:label];
    [v addSubview:pop];
    [v addSubview:self.always];
    return v;
}

- (void)done:(NSModalResponse)r {
    busy = false;
    if (r != NSModalResponseOK || self.panel.URL == nil) return set_result(2, nil);
    NSURL *app = self.panel.URL;
    NSString *name = [[app lastPathComponent] stringByDeletingPathExtension];
    if (self.always.state == NSControlStateValueOn)
        [[NSWorkspace sharedWorkspace] setDefaultApplicationAtURL:app
                                     toOpenContentTypeOfFileAtURL:self.file
                                                completionHandler:^(NSError *e) { (void)e; }];
    if (gtty_open_with([[self.file path] fileSystemRepresentation], [[app path] fileSystemRepresentation]) != 0)
        return set_result(-1, [NSString stringWithFormat:@"%@ could not open it", name]);
    set_result(1, name);
}
@end

static GttyAppChooser *chooser;

static void say(char *why, unsigned long len, const char *s) {
    if (len) snprintf(why, len, "%s", s);
}

int gtty_choose_app(void *sdl_window, const char *path, char *why, unsigned long len) {
    if (busy) {
        say(why, len, "the app chooser is already open");
        return 0;
    }
    @autoreleasepool {
        NSWindow *win = nil;
        if (sdl_window) {
            SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
            win = (NSWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        }
        NSURL *file = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        GttyAppChooser *ch = [[GttyAppChooser alloc] init];
        ch.file = file;
        NSMutableSet *rec = [NSMutableSet set];
        CFArrayRef apps = LSCopyApplicationURLsForURL((__bridge CFURLRef)file, kLSRolesAll);
        if (apps) {
            for (NSURL *u in (__bridge NSArray *)apps) [rec addObject:[[u URLByResolvingSymlinksInPath] path]];
            CFRelease(apps);
        }
        ch.recommended = rec;
        ch.all = [rec count] == 0; // nothing recommended: every app

        NSOpenPanel *p = [NSOpenPanel openPanel];
        ch.panel = p;
        p.delegate = ch;
        p.canChooseFiles = YES;
        p.canChooseDirectories = NO;
        p.allowsMultipleSelection = NO;
        p.treatsFilePackagesAsDirectories = NO;
        p.allowedContentTypes = @[ UTTypeApplicationBundle ];
        p.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
        p.prompt = @"Open";
        p.message = [NSString stringWithFormat:@"Choose an application to open the document “%@”.", [file lastPathComponent]];
        p.accessoryView = [ch accessory];
        p.accessoryViewDisclosed = YES;

        chooser = ch;
        busy = true;
        result = 0;
        void (^handler)(NSModalResponse) = ^(NSModalResponse r) {
          [ch done:r];
          if (chooser == ch) chooser = nil;
        };
        if (win) [p beginSheetModalForWindow:win completionHandler:handler];
        else [p beginWithCompletionHandler:handler];
    }
    return 1;
}

int gtty_choose_app_take(char *name, unsigned long len) {
    int r = result;
    result = 0;
    if (r != 0 && len) snprintf(name, len, "%s", result_text);
    return r;
}

int gtty_app_icon(const char *id, int px, unsigned char *rgba) {
    if (!id || px <= 0) return 0;
    @autoreleasepool {
        NSImage *img = [[NSWorkspace sharedWorkspace] iconForFile:[NSString stringWithUTF8String:id]];
        if (img == nil) return 0;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                        pixelsWide:px
                                                                        pixelsHigh:px
                                                                     bitsPerSample:8
                                                                   samplesPerPixel:4
                                                                          hasAlpha:YES
                                                                          isPlanar:NO
                                                                    colorSpaceName:NSDeviceRGBColorSpace
                                                                       bytesPerRow:px * 4
                                                                      bitsPerPixel:32];
        NSGraphicsContext *ctx = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
        if (ctx == nil) return 0;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];
        ctx.imageInterpolation = NSImageInterpolationHigh;
        [img drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        memcpy(rgba, [rep bitmapData], (size_t)px * (size_t)px * 4);
    }
    return 1;
}
