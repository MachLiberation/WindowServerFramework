//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Devil horns on every window (WXFDecor.h), behind it, so the window looks like it grew them. The
// horns are drawn here with CoreGraphics; the framework puts them in the window's own layer tree,
// where they move, stack and fade with it.
//
// No CALayer is touched here, only CGImages handed to the framework, which does its layer work
// inside the transactions WindowServer needs (see WXFDecor.h).

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFDecor.h>
#include <os/log.h>
#include <stdlib.h>

static const CGFloat kScale = 2;                 // pictures are drawn at 2x
static const CGSize  kHornSize = { 60, 90 };

// --- Art ------------------------------------------------------------------------------------
typedef struct { CGFloat base[3], tip[3], edge[3]; } Coat;
static const Coat kCoats[] = {
    { {0.80, 0.06, 0.08}, {1.00, 0.35, 0.25}, {0.35, 0.00, 0.02} },  // red
};

// A horn standing on its base and curling outward to a sharp tip, shaded from base to tip, with a
// dark outline and a few ridges. The right horn is the mirror image.
static CGImageRef MakeHorn(const Coat *coat, bool right) {
    size_t w = kHornSize.width * kScale, h = kHornSize.height * kScale;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!c) { CGColorSpaceRelease(space); return NULL; }
    CGContextScaleCTM(c, kScale, kScale);
    if (right) {
        CGContextTranslateCTM(c, kHornSize.width, 0);
        CGContextScaleCTM(c, -1, 1);
    }
    // CoreGraphics is y up: the base sits at the bottom, the tip curls up and out to the left.
    CGMutablePathRef horn = CGPathCreateMutable();
    CGPathMoveToPoint(horn, NULL, 18, 4);
    CGPathAddCurveToPoint(horn, NULL, 10, 30, 2, 58, 6, 86);       // outer edge up to the tip
    CGPathAddCurveToPoint(horn, NULL, 18, 62, 36, 38, 52, 4);      // inner edge back to the base
    CGPathCloseSubpath(horn);

    CGContextSaveGState(c);
    CGContextAddPath(c, horn);
    CGContextClip(c);
    CGFloat stops[] = { coat->base[0], coat->base[1], coat->base[2], 1, coat->tip[0], coat->tip[1], coat->tip[2], 1 };
    CGGradientRef g = CGGradientCreateWithColorComponents(space, stops, NULL, 2);
    CGContextDrawLinearGradient(c, g, CGPointMake(35, 4), CGPointMake(6, 86), 0);
    CGGradientRelease(g);
    CGContextSetRGBStrokeColor(c, coat->edge[0], coat->edge[1], coat->edge[2], 0.45);   // ridges
    CGContextSetLineWidth(c, 1.5);
    for (int i = 1; i <= 4; i++) {
        CGFloat y = 4 + i * 14;
        CGContextMoveToPoint(c, 0, y + 4);
        CGContextAddQuadCurveToPoint(c, 26, y - 4, 56, y + 2);
    }
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    CGContextAddPath(c, horn);
    CGContextSetRGBStrokeColor(c, coat->edge[0], coat->edge[1], coat->edge[2], 1);
    CGContextSetLineWidth(c, 2);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextStrokePath(c);
    CGPathRelease(horn);
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

static CGImageRef gHorns[2];                     // left, right; made once, kept for good

// --- Rule -----------------------------------------------------------------------------------
static void Setup(WXFDecorID decor, const WXFDecorWindowInfo *window, void *userInfo) {
    (void)userInfo;
    // On the top edge, in from each corner, leaning outward, behind the window with their base 8
    // points under it so they look rooted.
    for (int side = 0; side < 2; side++) {
        CGPoint corner = side ? (CGPoint){1, 0} : (CGPoint){0, 0};
        WXFDecorPlacement p = WXFDecorPlacementMake(corner, (CGPoint){0.5, 1}, (CGPoint){side ? -70 : 70, 8});
        p.rotation = side ? 0.22 : -0.22;
        WXFDecorElementID horn = WXFDecorAddImage(decor, gHorns[side], kScale, p);
        WXFDecorElementSetBelowWindow(horn, true);
    }
    os_log(OS_LOG_DEFAULT, "WXF decor example: horns on window %u (%.0fx%.0f)", window->window,
           window->frame.size.width, window->frame.size.height);
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    for (int side = 0; side < 2; side++) gHorns[side] = MakeHorn(&kCoats[0], side);
    WXFDecorRule rule = { .setup = Setup };
    WXFDecorRuleID id = WXFDecorAddRule(&rule);
    os_log(OS_LOG_DEFAULT, "WXF decor example: loaded, available %d, rule %u", WXFDecorIsAvailable(), id);
}
