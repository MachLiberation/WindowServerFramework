// wxf-wallpaper: paints an image onto the X root window. The X session has no desktop program
// (xfdesktop isn't installed), so this stands in: it decodes any image with ImageIO, scales it to fill
// the screen, and sets the root pixmap (and _XROOTPMAP_ID, which compositors read).
//
//   wxf-wallpaper <image>
//
// Built by xfce-session.sh. Credit: bedtime.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wxf-wallpaper <image>\n"); return 2; }
    @autoreleasepool {
        CGImageSourceRef src = CGImageSourceCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL);
        CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (!image) { fprintf(stderr, "wxf-wallpaper: can't read %s\n", argv[1]); return 1; }

        Display *dpy = XOpenDisplay(NULL);
        if (!dpy) { fprintf(stderr, "wxf-wallpaper: no X display\n"); return 1; }
        int screen = DefaultScreen(dpy);
        int sw = DisplayWidth(dpy, screen), sh = DisplayHeight(dpy, screen);
        Window root = RootWindow(dpy, screen);

        // BGRX bytes, the layout of a 24-bit TrueColor X visual with the usual masks.
        size_t stride = (size_t)sw * 4;
        char *pixels = calloc(stride, sh);
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        CGContextRef cg = CGBitmapContextCreate(pixels, sw, sh, 8, stride, rgb,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
        // Scale to fill, centered.
        double iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
        double k = MAX(sw / iw, sh / ih);
        CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
        CGContextDrawImage(cg, CGRectMake((sw - iw * k) / 2, (sh - ih * k) / 2, iw * k, ih * k), image);

        Pixmap pm = XCreatePixmap(dpy, root, sw, sh, DefaultDepth(dpy, screen));
        XImage *xi = XCreateImage(dpy, DefaultVisual(dpy, screen), DefaultDepth(dpy, screen), ZPixmap, 0,
                                  pixels, sw, sh, 32, (int)stride);
        XPutImage(dpy, pm, DefaultGC(dpy, screen), xi, 0, 0, 0, 0, sw, sh);

        XSetWindowBackgroundPixmap(dpy, root, pm);
        XClearWindow(dpy, root);
        Atom ids[2] = { XInternAtom(dpy, "_XROOTPMAP_ID", False), XInternAtom(dpy, "ESETROOT_PMAP_ID", False) };
        for (int i = 0; i < 2; i++)
            XChangeProperty(dpy, root, ids[i], XA_PIXMAP, 32, PropModeReplace, (unsigned char *)&pm, 1);
        // The pixmap must outlive this client or the root goes back to black.
        XSetCloseDownMode(dpy, RetainPermanent);
        XSync(dpy, False);
        XCloseDisplay(dpy);
    }
    return 0;
}
