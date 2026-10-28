//
//  TBChrome.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//

#import "TBChrome.h"

const NSInteger TBLevelBase = 24;
const NSInteger TBLevelCover = 25;

@implementation TBPanel

+ (instancetype)panelWithFrame:(NSRect)frame level:(NSInteger)level {
    TBPanel *panel = [[TBPanel alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.level = level;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = NO;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorIgnoresCycle |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    return panel;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }

// AppKit pushes a window below the menu bar (and the notch's safe area) unless it is told not to;
// the taskbar sits exactly there.
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }

@end

@implementation TBBackgroundView

- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect bounds = self.bounds;
    NSGradient *fill = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.085 green:0.085 blue:0.098 alpha:1]
                                                     endingColor:[NSColor colorWithSRGBRed:0.125 green:0.125 blue:0.142 alpha:1]];
    [fill drawInRect:bounds angle:90];    // lighter toward the top edge of the display
    [[NSColor colorWithWhite:1 alpha:0.045] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, NSMaxY(bounds) - 1, NSWidth(bounds), 1), NSCompositingOperationSourceOver);
    [[NSColor colorWithWhite:1 alpha:0.10] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(bounds), 1), NSCompositingOperationSourceOver);
}

@end
