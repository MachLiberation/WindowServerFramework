//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// A 2016 Chrome tab on top of every window (WXFDecor.h): slanted sides, a light gradient, the
// application's icon and name. On a window too narrow for the name, the tab shrinks to the icon. The
// tab sits behind the window, so its bottom edge tucks under the title bar.
//
// The name and bundle come from WXFDecorWindowInfo (WindowServer's own process records); the icon is
// read from the bundle with ImageIO and everything is drawn here with CoreGraphics and CoreText. No
// CALayer is touched here (see WXFDecor.h).

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFDecor.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

static const CGFloat kScale = 2;                 // drawn at 2x
static const CGFloat kTabHeight = 28;
static const CGFloat kFullWidth = 220;           // Chrome's widest tab
static const CGFloat kCompactWidth = 52;         // just the icon
static const CGFloat kSlant = 14;                // how far each side leans in over the tab's height
static const CGFloat kIconSize = 16;
static const CGFloat kInset = 12;                // from the window's left edge
static const CGFloat kSink = 3;                  // tucked under the window's top edge

// --- Icons ----------------------------------------------------------------------------------
// The bundle's .icns (CFBundleIconFile, else CFBundleIconName), the representation closest to 32 px.
// Read once per bundle.
static CGImageRef LoadIcon(const char *bundlePath) {
    if (!bundlePath[0]) return NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bundlePath, strlen(bundlePath), true);
    CFBundleRef bundle = url ? CFBundleCreate(NULL, url) : NULL;
    if (url) CFRelease(url);
    if (!bundle) return NULL;
    CGImageRef best = NULL;
    const CFStringRef keys[] = { CFSTR("CFBundleIconFile"), CFSTR("CFBundleIconName") };
    for (int k = 0; k < 2 && !best; k++) {
        CFTypeRef name = CFBundleGetValueForInfoDictionaryKey(bundle, keys[k]);
        if (!name || CFGetTypeID(name) != CFStringGetTypeID()) continue;
        CFMutableStringRef base = CFStringCreateMutableCopy(NULL, 0, name);
        if (CFStringHasSuffix(base, CFSTR(".icns")))
            CFStringDelete(base, CFRangeMake(CFStringGetLength(base) - 5, 5));
        CFURLRef icns = CFBundleCopyResourceURL(bundle, base, CFSTR("icns"), NULL);
        CFRelease(base);
        CGImageSourceRef source = icns ? CGImageSourceCreateWithURL(icns, NULL) : NULL;
        if (icns) CFRelease(icns);
        if (!source) continue;
        size_t bestIndex = 0, bestWidth = 0;
        for (size_t i = 0; i < CGImageSourceGetCount(source); i++) {
            CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
            int w = 0;
            CFNumberRef n = props ? CFDictionaryGetValue(props, kCGImagePropertyPixelWidth) : NULL;
            if (n) CFNumberGetValue(n, kCFNumberIntType, &w);
            if (props) CFRelease(props);
            // The smallest at least 32 px wide, else the largest.
            bool better = bestWidth == 0 || (w >= 32 && (bestWidth < 32 || (size_t)w < bestWidth)) ||
                          (bestWidth < 32 && (size_t)w > bestWidth);
            if (better) { bestIndex = i; bestWidth = w; }
        }
        if (bestWidth) best = CGImageSourceCreateImageAtIndex(source, bestIndex, NULL);
        CFRelease(source);
    }
    CFRelease(bundle);
    return best;
}

typedef struct IconEntry { char path[1024]; CGImageRef icon; struct IconEntry *next; } IconEntry;
static IconEntry *gIcons;

static CGImageRef IconFor(const char *bundlePath) {
    for (IconEntry *e = gIcons; e; e = e->next)
        if (strcmp(e->path, bundlePath) == 0) return e->icon;
    IconEntry *e = calloc(1, sizeof *e);
    strlcpy(e->path, bundlePath, sizeof e->path);
    e->icon = LoadIcon(bundlePath);
    e->next = gIcons;
    gIcons = e;
    return e->icon;
}

// --- The tab --------------------------------------------------------------------------------
// The outline of a 2016 Chrome tab, `w` wide, in CoreGraphics coordinates (y up, base at y = 0):
// sides leaning in with a soft curve at the bottom and the top.
static CGPathRef TabPath(CGFloat w, CGFloat h) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 0, 0);
    CGPathAddCurveToPoint(p, NULL, kSlant * 0.35, 0, kSlant * 0.4, h * 0.3, kSlant * 0.5, h * 0.5);
    CGPathAddCurveToPoint(p, NULL, kSlant * 0.6, h * 0.75, kSlant * 0.7, h, kSlant + 2, h);
    CGPathAddLineToPoint(p, NULL, w - kSlant - 2, h);
    CGPathAddCurveToPoint(p, NULL, w - kSlant * 0.7, h, w - kSlant * 0.6, h * 0.75, w - kSlant * 0.5, h * 0.5);
    CGPathAddCurveToPoint(p, NULL, w - kSlant * 0.4, h * 0.3, w - kSlant * 0.35, 0, w, 0);
    CGPathCloseSubpath(p);
    return p;
}

// A tab `w` points wide with the icon and, if there is room, the name (cut with an ellipsis).
static CGImageRef MakeTab(CGFloat w, CGImageRef icon, CFStringRef name) {
    CGFloat h = kTabHeight;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, (size_t)(w * kScale), (size_t)(h * kScale), 8, 0, space,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!c) { CGColorSpaceRelease(space); return NULL; }
    CGContextScaleCTM(c, kScale, kScale);

    CGPathRef path = TabPath(w, h);
    CGContextSaveGState(c);
    CGContextAddPath(c, path);
    CGContextClip(c);
    CGFloat stops[] = { 0.98, 0.98, 0.98, 1,   0.89, 0.89, 0.90, 1 };   // top, bottom
    CGGradientRef g = CGGradientCreateWithColorComponents(space, stops, NULL, 2);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, h), CGPointMake(0, 0), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
    CGContextAddPath(c, path);
    CGContextSetRGBStrokeColor(c, 0.55, 0.55, 0.57, 1);
    CGContextSetLineWidth(c, 1);
    CGContextStrokePath(c);
    CGPathRelease(path);

    // The icon, or a gray rounded square with nothing to show.
    CGFloat contentY = (h - kSink - kIconSize) / 2 + kSink;   // centred over the visible part
    CGFloat iconX = name ? kSlant + 6 : (w - kIconSize) / 2;
    CGRect iconRect = CGRectMake(iconX, contentY, kIconSize, kIconSize);
    if (icon) {
        CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
        CGContextDrawImage(c, iconRect, icon);
    } else {
        CGPathRef r = CGPathCreateWithRoundedRect(iconRect, 4, 4, NULL);
        CGContextAddPath(c, r);
        CGContextSetRGBFillColor(c, 0.6, 0.6, 0.62, 1);
        CGContextFillPath(c);
        CGPathRelease(r);
    }

    if (name) {
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12, NULL);
        CGColorRef ink = CGColorCreate(space, (CGFloat[]){ 0.2, 0.2, 0.22, 1 });
        const void *k[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *v[] = { font, ink };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef text = CFAttributedStringCreate(NULL, name, attrs);
        CTLineRef line = CTLineCreateWithAttributedString(text);
        CFAttributedStringRef dots = CFAttributedStringCreate(NULL, CFSTR("…"), attrs);
        CTLineRef ellipsis = CTLineCreateWithAttributedString(dots);
        CGFloat textX = iconX + kIconSize + 6, room = w - kSlant - 6 - textX;
        CTLineRef fitted = CTLineCreateTruncatedLine(line, room, kCTLineTruncationEnd, ellipsis);
        CGFloat ascent, descent;
        CTLineGetTypographicBounds(fitted ? fitted : line, &ascent, &descent, NULL);
        CGContextSetTextPosition(c, textX, contentY + (kIconSize - ascent + descent) / 2);
        CTLineDraw(fitted ? fitted : line, c);
        if (fitted) CFRelease(fitted);
        CFRelease(ellipsis); CFRelease(dots); CFRelease(line); CFRelease(text); CFRelease(attrs);
        CGColorRelease(ink); CFRelease(font);
    }
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

// --- A tab per window -----------------------------------------------------------------------
typedef struct { WXFDecorElementID full, compact; } Tab;

// One Tab per decor, found again by id when the window is resized.
typedef struct TabEntry { WXFDecorID decor; Tab tab; struct TabEntry *next; } TabEntry;
static TabEntry *gTabs;

// The full tab needs the window to be at least this wide; narrower, the icon-only tab shows.
static void ShowFitting(const Tab *tab, CGFloat windowWidth) {
    bool full = windowWidth >= kFullWidth + 2 * kInset + 40;
    WXFDecorElementSetHidden(tab->full, !full);
    WXFDecorElementSetHidden(tab->compact, full);
}

static WXFDecorElementID AddTab(WXFDecorID decor, CGImageRef image, CGFloat width) {
    WXFDecorPlacement p = WXFDecorPlacementMake((CGPoint){0, 0}, (CGPoint){0, 1}, (CGPoint){kInset, kSink});
    p.size = CGSizeMake(width, kTabHeight);
    WXFDecorElementID e = WXFDecorAddImage(decor, image, kScale, p);
    WXFDecorElementSetBelowWindow(e, true);
    return e;
}

static void Setup(WXFDecorID decor, const WXFDecorWindowInfo *window, void *userInfo) {
    (void)userInfo;
    CGImageRef icon = IconFor(window->bundlePath);
    CFStringRef name = CFStringCreateWithCString(NULL, window->appName[0] ? window->appName : "Window",
                                                 kCFStringEncodingUTF8);
    CGImageRef full = MakeTab(kFullWidth, icon, name);
    CGImageRef compact = MakeTab(kCompactWidth, icon, NULL);
    CFRelease(name);
    TabEntry *entry = calloc(1, sizeof *entry);       // per window, kept for the process
    entry->decor = decor;
    entry->next = gTabs;
    gTabs = entry;
    Tab *tab = &entry->tab;
    tab->full = AddTab(decor, full, kFullWidth);
    tab->compact = AddTab(decor, compact, kCompactWidth);
    if (full) CGImageRelease(full);                   // the decor keeps its own reference
    if (compact) CGImageRelease(compact);
    ShowFitting(tab, window->frame.size.width);
    os_log(OS_LOG_DEFAULT, "WXF decor tab example: tab on window %u for \"%s\" (%s), icon %d",
           window->window, window->appName, window->bundlePath, icon != NULL);
}

static void Resized(WXFDecorID decor, const WXFDecorWindowInfo *window, void *userInfo) {
    (void)userInfo;
    for (TabEntry *e = gTabs; e; e = e->next)
        if (e->decor == decor) { ShowFitting(&e->tab, window->frame.size.width); return; }
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    WXFDecorRule rule = { .setup = Setup, .resized = Resized };
    WXFDecorRuleID id = WXFDecorAddRule(&rule);
    os_log(OS_LOG_DEFAULT, "WXF decor tab example: loaded, available %d, rule %u", WXFDecorIsAvailable(), id);
}
