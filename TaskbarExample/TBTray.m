//
//  TBTray.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//

#import "TBTray.h"
#import "TBChrome.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static const NSInteger kTBLevelFlyout = 27;
static const CGFloat kPad = 10;
static const CGFloat kCellH = 44;
static const CGFloat kCellMinW = 44;
static const CGFloat kCellGap = 4;
static const CGFloat kMaxRowW = 5 * kCellMinW + 4 * kCellGap;

#pragma mark - Chevron

@implementation TBChevronView {
    BOOL _hover, _pressed;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setOpen:(BOOL)open {
    if (open == _open) return;
    _open = open;
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event { _hover = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { _hover = NO; _pressed = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event { _pressed = YES; self.needsDisplay = YES; }

- (void)mouseUp:(NSEvent *)event {
    BOOL inside = NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds);
    _pressed = NO;
    self.needsDisplay = YES;
    if (inside && self.action) self.action();
}

- (void)drawRect:(NSRect)dirty {
    CGFloat fill = _pressed ? 0.18 : ((_hover || _open) ? 0.11 : 0);
    if (fill > 0) {
        [[NSColor colorWithWhite:1 alpha:fill] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:7 yRadius:7] fill];
    }
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:nil];
    symbol = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]];
    NSSize size = symbol.size;
    NSImage *tinted = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [symbol drawInRect:rect];
        [[NSColor colorWithWhite:1 alpha:0.88] set];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
        return YES;
    }];
    // Points up when the flyout is closed (it will open upward in spirit), down when open.
    NSAffineTransform *flip = [NSAffineTransform transform];
    [flip translateXBy:NSMidX(self.bounds) yBy:NSMidY(self.bounds)];
    if (_open) [flip scaleXBy:1 yBy:-1];
    [NSGraphicsContext saveGraphicsState];
    [flip concat];
    [tinted drawInRect:NSMakeRect(-size.width / 2, -size.height / 2, size.width, size.height)];
    [NSGraphicsContext restoreGraphicsState];
}

@end

#pragma mark - Pinned icons

static const CGFloat kBarCellH = 38;
static const CGFloat kBarCellMinW = 34;
static const CGFloat kBarCellPad = 12;
static const CGFloat kBarCellGap = 2;

@implementation TBTrayBarView {
    NSArray<TBStatusItem *> *_items;
    NSMutableArray<NSValue *> *_cells;
    NSMutableArray<CALayer *> *_hosts;
    NSInteger _hover, _pressed;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _items = @[];
        _cells = [NSMutableArray array];
        _hosts = [NSMutableArray array];
        _hover = _pressed = -1;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (CGFloat)setItems:(NSArray<TBStatusItem *> *)items {
    _items = [items copy];
    for (CALayer *host in _hosts) [host removeFromSuperlayer];
    [_hosts removeAllObjects];
    [_cells removeAllObjects];
    Class hostClass = NSClassFromString(@"CALayerHost");
    CGFloat y = floor((NSHeight(self.bounds) - kBarCellH) / 2) - 1;
    CGFloat x = 0;
    for (TBStatusItem *item in items) {
        CGFloat w = MAX(kBarCellMinW, item.size.width + kBarCellPad);
        NSRect cell = NSMakeRect(x, y, w, kBarCellH);
        [_cells addObject:[NSValue valueWithRect:cell]];
        x += w + kBarCellGap;

        CALayer *host = nil;
        if (item.contextId && hostClass) {
            host = [[hostClass alloc] init];
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(host, NSSelectorFromString(@"setContextId:"), item.contextId);
            host.bounds = CGRectMake(0, 0, item.size.width, item.size.height);
            host.position = CGPointMake(NSMidX(cell), NSMidY(cell));
            host.geometryFlipped = YES;        // this view is flipped
            [self.layer addSublayer:host];
        }
        [_hosts addObject:host ?: [CALayer layer]];
    }
    self.needsDisplay = YES;
    return items.count ? x - kBarCellGap : 0;
}

- (void)drawRect:(NSRect)dirty {
    for (NSUInteger i = 0; i < _cells.count; i++) {
        CGFloat fill = (NSInteger)i == _pressed ? 0.16 : ((NSInteger)i == _hover ? 0.09 : 0);
        if (fill <= 0) continue;
        [[NSColor colorWithWhite:1 alpha:fill] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:_cells[i].rectValue xRadius:8 yRadius:8] fill];
    }
}

- (NSInteger)cellAtPoint:(NSPoint)point {
    for (NSUInteger i = 0; i < _cells.count; i++)
        if (NSPointInRect(point, _cells[i].rectValue)) return (NSInteger)i;
    return -1;
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
- (void)mouseExited:(NSEvent *)event { [self setHover:-1]; _pressed = -1; }

- (void)mouseDown:(NSEvent *)event {
    _pressed = [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    self.needsDisplay = YES;
}

- (void)clickedWithEvent:(NSEvent *)event right:(BOOL)right {
    NSInteger cell = [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    _pressed = -1;
    self.needsDisplay = YES;
    if (cell < 0 || cell >= (NSInteger)_items.count || !self.pick) return;
    NSRect inScreen = [self.window convertRectToScreen:[self convertRect:_cells[cell].rectValue toView:nil]];
    self.pick(_items[cell], right, NSMinX(inScreen));
}

- (void)mouseUp:(NSEvent *)event { [self clickedWithEvent:event right:NO]; }
- (void)rightMouseUp:(NSEvent *)event { [self clickedWithEvent:event right:YES]; }

@end

#pragma mark - Flyout

@interface TBFlyoutView : NSView
@property (nonatomic, copy) NSArray<TBStatusItem *> *items;
@property (nonatomic, copy, nullable) void (^pick)(TBStatusItem *, BOOL, CGFloat);
- (NSSize)layoutItems;
@end

@implementation TBFlyoutView {
    NSMutableArray<NSValue *> *_cells;
    NSMutableArray<CALayer *> *_hosts;
    NSInteger _hover;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _cells = [NSMutableArray array];
        _hosts = [NSMutableArray array];
        _hover = -1;
        _items = @[];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// Lays the cells out in rows and gives each a copy of its item's picture. Returns the size needed.
- (NSSize)layoutItems {
    for (CALayer *host in _hosts) [host removeFromSuperlayer];
    [_hosts removeAllObjects];
    [_cells removeAllObjects];
    Class hostClass = NSClassFromString(@"CALayerHost");

    CGFloat x = 0, y = 0, widest = 0;
    for (TBStatusItem *item in _items) {
        CGFloat w = MAX(kCellMinW, item.size.width + 14);
        if (x > 0 && x + w > kMaxRowW) { x = 0; y += kCellH + kCellGap; }
        NSRect cell = NSMakeRect(kPad + x, kPad + y, w, kCellH);
        [_cells addObject:[NSValue valueWithRect:cell]];
        x += w + kCellGap;
        widest = MAX(widest, x - kCellGap);

        CALayer *host = nil;
        if (item.contextId && hostClass) {
            host = [[hostClass alloc] init];
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(host, NSSelectorFromString(@"setContextId:"), item.contextId);
            host.bounds = CGRectMake(0, 0, item.size.width, item.size.height);
            host.position = CGPointMake(NSMidX(cell), NSMidY(cell));
            // The view is flipped, so the picture would come out upside down.
            host.geometryFlipped = YES;
            [self.layer addSublayer:host];
        }
        [_hosts addObject:host ?: [CALayer layer]];
    }
    NSSize size = NSMakeSize(kPad * 2 + MAX(widest, kCellMinW), kPad * 2 + y + kCellH);
    self.needsDisplay = YES;
    return size;
}

- (void)drawRect:(NSRect)dirty {
    for (NSUInteger i = 0; i < _cells.count; i++) {
        if ((NSInteger)i != _hover) continue;
        [[NSColor colorWithWhite:1 alpha:0.10] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:_cells[i].rectValue xRadius:8 yRadius:8] fill];
    }
}

- (NSInteger)cellAtPoint:(NSPoint)point {
    for (NSUInteger i = 0; i < _cells.count; i++)
        if (NSPointInRect(point, _cells[i].rectValue)) return (NSInteger)i;
    return -1;
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
- (void)mouseExited:(NSEvent *)event { [self setHover:-1]; }

- (void)clickedWithEvent:(NSEvent *)event right:(BOOL)right {
    NSInteger cell = [self cellAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (cell < 0 || cell >= (NSInteger)_items.count || !self.pick) return;
    NSRect inScreen = [self.window convertRectToScreen:[self convertRect:_cells[cell].rectValue toView:nil]];
    self.pick(_items[cell], right, NSMinX(inScreen));
}

- (void)mouseUp:(NSEvent *)event { [self clickedWithEvent:event right:NO]; }
- (void)rightMouseUp:(NSEvent *)event { [self clickedWithEvent:event right:YES]; }

@end

@implementation TBTrayFlyout {
    TBPanel *_panel;
    TBFlyoutView *_view;
    id _monitor;
    NSPoint _corner;
}

- (BOOL)shown { return _panel.visible; }

- (void)showWithItems:(NSArray<TBStatusItem *> *)items topRight:(NSPoint)corner {
    if (!_panel) {
        _panel = [TBPanel panelWithFrame:NSMakeRect(0, 0, 100, 100) level:kTBLevelFlyout];
        _panel.hasShadow = YES;
        _view = [[TBFlyoutView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        _view.layer.cornerRadius = 12;
        _view.layer.masksToBounds = YES;
        _view.layer.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:0.98].CGColor;
        _view.layer.borderWidth = 1;
        _view.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.10].CGColor;
        __weak TBTrayFlyout *weakSelf = self;
        _view.pick = ^(TBStatusItem *item, BOOL right, CGFloat screenX) {
            TBTrayFlyout *strongSelf = weakSelf;
            if (strongSelf.pick) strongSelf.pick(item, right, screenX);
            [strongSelf hide];
        };
        _panel.contentView = _view;
    }
    _corner = corner;
    [self updateItems:items];
    [_panel orderFrontRegardless];

    // A click anywhere outside closes it; clicks on this process's own windows aren't global, and
    // the chevron handles its own.
    if (!_monitor) {
        __weak TBTrayFlyout *weakSelf = self;
        _monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                                          handler:^(NSEvent *event) { [weakSelf hide]; }];
    }
}

- (void)updateItems:(NSArray<TBStatusItem *> *)items {
    if (!_panel) return;
    _view.items = items;
    NSSize size = [_view layoutItems];
    NSRect frame = NSMakeRect(_corner.x - size.width, _corner.y - size.height, size.width, size.height);
    [_panel setFrame:frame display:YES];
    _view.frame = NSMakeRect(0, 0, size.width, size.height);
}

- (void)hide {
    if (_monitor) { [NSEvent removeMonitor:_monitor]; _monitor = nil; }
    if (!_panel.visible) return;
    [_panel orderOut:nil];
    if (self.didHide) self.didHide();
}

@end
