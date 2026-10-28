//
//  TBStripView.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//

#import "TBStripView.h"

static const CGFloat kInset = 10;       // before the first cell
static const CGFloat kCellW = 44;
static const CGFloat kCellH = 38;
static const CGFloat kGap = 2;
static const CGFloat kIcon = 26;
static const NSInteger kNone = -1;

@implementation TBStripView {
    NSArray<NSRunningApplication *> *_apps;       // every app, in order
    NSArray<NSRunningApplication *> *_shown;      // the ones with a cell of their own
    NSArray<NSRunningApplication *> *_overflow;   // the rest, behind the last cell
    pid_t _activePid;
    NSUInteger _signature;                        // of the active app and which apps are hidden
    NSInteger _hover;
    NSInteger _pressed;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _hover = _pressed = kNone;
        _apps = _shown = _overflow = @[];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

#pragma mark - Layout

- (NSRect)rectForCell:(NSInteger)index {
    return NSMakeRect(kInset + index * (kCellW + kGap), floor((NSHeight(self.bounds) - kCellH) / 2) - 1, kCellW, kCellH);
}

- (BOOL)hasOverflowCell { return _overflow.count > 0; }
- (NSInteger)cellCount { return (NSInteger)_shown.count + ([self hasOverflowCell] ? 1 : 0); }

- (void)relayout {
    NSInteger capacity = MAX(0, (NSInteger)floor((_availableWidth - 2 * kInset + kGap) / (kCellW + kGap)));
    if ((NSInteger)_apps.count <= capacity) {
        _shown = _apps;
        _overflow = @[];
    } else {
        // The last cell is the overflow menu.
        NSInteger keep = MAX(0, capacity - 1);
        _shown = [_apps subarrayWithRange:NSMakeRange(0, keep)];
        _overflow = [_apps subarrayWithRange:NSMakeRange(keep, _apps.count - keep)];
    }
    _hover = _pressed = kNone;

    [self removeAllToolTips];
    for (NSInteger i = 0; i < [self cellCount]; i++)
        [self addToolTipRect:[self rectForCell:i] owner:self userData:(void *)(intptr_t)i];
    self.needsDisplay = YES;
}

- (void)setAvailableWidth:(CGFloat)width {
    if (fabs(width - _availableWidth) < 0.5) return;
    _availableWidth = width;
    [self relayout];
}

- (void)setApps:(NSArray<NSRunningApplication *> *)apps activePid:(pid_t)activePid {
    BOOL sameList = apps.count == _apps.count;
    for (NSUInteger i = 0; sameList && i < apps.count; i++)
        sameList = apps[i].processIdentifier == _apps[i].processIdentifier;
    NSUInteger signature = (NSUInteger)activePid;
    for (NSRunningApplication *app in apps) signature = signature * 31 + (app.hidden ? 7 : 3);
    if (sameList && signature == _signature) return;
    _signature = signature;
    _activePid = activePid;
    _apps = [apps copy];
    if (sameList) self.needsDisplay = YES; else [self relayout];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSInteger index = (NSInteger)(intptr_t)data;
    if (index < (NSInteger)_shown.count) return _shown[index].localizedName;
    return [NSString stringWithFormat:@"%lu more", (unsigned long)_overflow.count];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirty {
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    NSColor *accent = NSColor.controlAccentColor;
    for (NSInteger i = 0; i < [self cellCount]; i++) {
        NSRect cell = [self rectForCell:i];
        BOOL isOverflow = i >= (NSInteger)_shown.count;
        NSRunningApplication *app = isOverflow ? nil : _shown[i];
        BOOL active = app && app.processIdentifier == _activePid;

        CGFloat fill = 0;
        if (active) fill = 0.13;
        if (i == _hover) fill = MAX(fill, 0.09) + (active ? 0.03 : 0);
        if (i == _pressed) fill += 0.06;
        if (fill > 0) {
            [[NSColor colorWithWhite:1 alpha:fill] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:9 yRadius:9] fill];
        }

        if (isOverflow) {
            [[NSColor colorWithWhite:1 alpha:0.75] setFill];
            for (int dot = -1; dot <= 1; dot++)
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(cell) - 2 + dot * 7, NSMidY(cell) - 2, 4, 4)] fill];
            continue;
        }

        NSRect iconRect = NSMakeRect(NSMidX(cell) - kIcon / 2, NSMidY(cell) - kIcon / 2 - 1, kIcon, kIcon);
        // Down a point while the mouse is held on it.
        if (i == _pressed) iconRect = NSOffsetRect(NSInsetRect(iconRect, 1, 1), 0, 0.5);
        [app.icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                    fraction:app.hidden ? 0.45 : 1 respectFlipped:YES hints:nil];

        // The indicator under the icon: a pill for the frontmost app, a dot for the rest.
        if (active) {
            [accent setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMidX(cell) - 7, NSMaxY(cell) - 3.5, 14, 3) xRadius:1.5 yRadius:1.5] fill];
        } else {
            [[NSColor colorWithWhite:1 alpha:0.5] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(cell) - 1.75, NSMaxY(cell) - 4, 3.5, 3.5)] fill];
        }
    }
}

#pragma mark - Mouse

- (NSInteger)cellAtPoint:(NSPoint)point {
    for (NSInteger i = 0; i < [self cellCount]; i++)
        if (NSPointInRect(point, [self rectForCell:i])) return i;
    return kNone;
}

- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
    [super updateTrackingAreas];
}

- (void)setHover:(NSInteger)hover {
    if (hover == _hover) return;
    _hover = hover;
    self.needsDisplay = YES;
}

- (void)mouseMoved:(NSEvent *)event { [self setHover:[self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]]; }
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event { [self setHover:kNone]; _pressed = kNone; }

- (void)mouseDown:(NSEvent *)event {
    // Control-click is the right button.
    if (event.modifierFlags & NSEventModifierFlagControl) { [self rightMouseDown:event]; return; }
    _pressed = [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    NSInteger pressed = _pressed;
    _pressed = kNone;
    self.needsDisplay = YES;
    if (pressed == kNone || pressed != [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]) return;
    if (pressed < (NSInteger)_shown.count)
        [self.delegate strip:self activateApp:_shown[pressed]];
    else
        [self showOverflowMenuFromCell:pressed];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSInteger cell = [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (cell == kNone) return;
    if (cell < (NSInteger)_shown.count)
        [self.delegate strip:self showMenusForApp:_shown[cell] cell:[self rectForCell:cell]];
    else
        [self showOverflowMenuFromCell:cell];
}

- (void)showOverflowMenuFromCell:(NSInteger)cell {
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSRunningApplication *app in _overflow) {
        NSMenuItem *item = [menu addItemWithTitle:app.localizedName ?: @"" action:@selector(overflowPicked:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = app;
        NSImage *icon = [app.icon copy];
        icon.size = NSMakeSize(16, 16);
        item.image = icon;
        if (app.processIdentifier == _activePid) item.state = NSControlStateValueOn;
    }
    [self popUpMenu:menu belowCell:[self rectForCell:cell]];
}

- (void)popUpMenu:(NSMenu *)menu belowCell:(NSRect)cell {
    // Opens downward from the cell's bottom edge, in this (flipped) view.
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(cell), NSMaxY(cell) + 6) inView:self];
}

- (void)overflowPicked:(NSMenuItem *)item {
    [self.delegate strip:self activateApp:item.representedObject];
}

@end
