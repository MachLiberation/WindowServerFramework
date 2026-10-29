//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// XFCE on a card0 connector. An X server (Xvfb) keeps its screen in a file; this tweak maps that file,
// draws it on a connector with the same takeover the cube uses (WXFCardSetUpdatesDisabled +
// WXFCardPresentExclusive), draws the pointer itself, and sends the keyboard and mouse WindowServer
// sees to the X server through a FIFO and a helper that replays them with XTEST (wxf-xinput.c).
//
// The X side runs as you, not inside WindowServer: XFCEExample/xfce-session.sh start
// Then, from a shell:
//
//   echo "seconds=120" > /private/tmp/wxf-xfce          show it on the internal display
//   echo "stop" > /private/tmp/wxf-xfce                 end it now
//   echo "seconds=120 pointer=1" > /private/tmp/wxf-xfce   also draw an arrow for the pointer
//
// macOS's own cursor stays on screen and is the pointer's position, so the arrow is off unless asked
// for (with it on there are two cursors).
//
// Or press Control+Option+Command+Escape. WindowServer's own drawing is off for the whole run and
// every key and mouse event is consumed, so these are the ways out; after `seconds` (default 120,
// at most 900) it ends by itself. A trigger file that is there when WindowServer starts is ignored.
// Read the result with  /usr/bin/log show --last 10m --process WindowServer | grep WXF
//
// The same tweak also runs inside Mac apps (the else branch of LoadFunction): an app started with
//   XFCEExample/xfce-open.sh Terminal
// has its windows shown on the X session, with the X session's keyboard and mouse sent back to it
// (XBridge.m; see StartBridgeInApp).

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFCard.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/WXFHost.h>
#include <WindowServerFramework/WXFMisc.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurface.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <mach-o/getsect.h>
#include <math.h>
#include <os/log.h>
#include <simd/simd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define TRIGGER_PATH       "/private/tmp/wxf-xfce"
#define FRAMEBUFFER_PATH   "/private/tmp/wxf-x11/Xvfb_screen0"
#define INPUT_FIFO_PATH    "/private/tmp/wxf-x11/input"
#define DEFAULT_SECONDS    120.0
#define MAX_SECONDS        900.0
#define FRAME_INTERVAL     (1.0 / 60.0)    // only when the connector reports no vblank
#define RENDER_LEAD        0.0025          // seconds before a vblank that a frame is started
#define VBLANK_FRESH       0.25
#define SURFACE_COUNT      4
#define MAX_FAILED_FRAMES  45

#define VK_ESCAPE  53
#define VK_COMMAND 55
#define VK_SHIFT   56
#define VK_OPTION  58
#define VK_CONTROL 59

typedef struct {
    simd_float2 screen, xSize, origin, pointer;
    float scale, cursorScale, nearest, showPointer;
} XfceUniforms;

typedef enum { Idle, Running } Phase;

static struct {
    Phase phase;
    WXFConnectorID connector;
    double begin, end, duration;
    int failedFrames;
    uint64_t frames;
    struct timespec lastTrigger;

    // The X screen, mapped from the XWD file the X server keeps up to date.
    void *map; size_t mapSize;
    const uint8_t *pixels;            // the file's pixels, which the X server is still writing to
    uint8_t *shadow;                  // a copy of them that did not change while it was taken
    bool drawPointer;
    uint64_t changedWhileCopying;     // frames where the X server painted during the copy
    uint32_t xWidth, xHeight, xStride;

    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> xTexture;
    IOSurfaceRef surfaces[SURFACE_COUNT];
    id<MTLTexture> targets[SURFACE_COUNT];
    unsigned next;
    uint32_t width, height;           // the display's surface, pixels

    // Where the X screen sits on the display, and the display's bounds in points, for the pointer.
    float scale, originX, originY;
    CGRect bounds;                    // pixels, as CAWindowServerDisplay reports it
    float pointWidth, pointHeight;    // the current mode's size in points: what event locations use

    // Frame timing, logged when the run ends.
    double lastFrameAt, period, sumInterval, maxInterval, maxRender, maxPresent;
    uint64_t slowIntervals, intervals, vblankFrames;

    WXFEventHandlerID handler;
    int fifo;
} S;

// Written by the event thread, read by the main thread. Plain loads and stores of one word.
static volatile float gPointerX, gPointerY;
static volatile int gStopRequested;
static volatile int gActive;
static uint32_t gPreviousFlags;
static double gScrollX, gScrollY;
static float gLastSentX = -1, gLastSentY = -1;

// --- The trigger file -----------------------------------------------------------------------

static bool TriggerTime(struct timespec *out) {
    struct stat st;
    if (stat(TRIGGER_PATH, &st) != 0) return false;
    *out = st.st_mtimespec;
    return true;
}

static bool Newer(struct timespec a, struct timespec b) {
    return a.tv_sec != b.tv_sec || a.tv_nsec != b.tv_nsec;
}

typedef struct { int connector; double seconds; bool stop; bool pointer; } Request;

static Request ReadRequest(void) {
    Request r = { .connector = -1, .seconds = DEFAULT_SECONDS };
    char text[256] = {0};
    FILE *f = fopen(TRIGGER_PATH, "r");
    if (f) { fread(text, 1, sizeof text - 1, f); fclose(f); }
    if (strstr(text, "stop")) r.stop = true;
    const char *p;
    if ((p = strstr(text, "connector="))) r.connector = atoi(p + 10);
    if ((p = strstr(text, "seconds=")))   r.seconds = atof(p + 8);
    if ((p = strstr(text, "pointer=")))   r.pointer = atoi(p + 8) != 0;
    if (r.seconds < 1) r.seconds = 1;
    if (r.seconds > MAX_SECONDS) r.seconds = MAX_SECONDS;
    return r;
}

// --- The X screen ---------------------------------------------------------------------------

// The file is an XWD: a big-endian header, a colour map, then the pixels (see the Xvfb -fbdir code
// and X11/XWDFile.h). Xvfb's 24-bit screen is 32 bits per pixel, blue in the low byte.
static void UnmapXScreen(void);

static bool MapXScreen(void) {
    int fd = open(FRAMEBUFFER_PATH, O_RDONLY);
    if (fd < 0) { os_log(OS_LOG_DEFAULT, "WXF xfce: cannot open %{public}s (is the X server running?)", FRAMEBUFFER_PATH); return false; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 160) { close(fd); return false; }
    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { os_log(OS_LOG_DEFAULT, "WXF xfce: mmap of the X screen failed"); return false; }

    const uint32_t *h = map;
    uint32_t headerSize = ntohl(h[0]), version = ntohl(h[1]), depth = ntohl(h[3]);
    uint32_t width = ntohl(h[4]), height = ntohl(h[5]), byteOrder = ntohl(h[7]);
    uint32_t bpp = ntohl(h[11]), stride = ntohl(h[12]);
    uint32_t red = ntohl(h[14]), green = ntohl(h[15]), blue = ntohl(h[16]), colors = ntohl(h[19]);
    size_t pixelOffset = (size_t)headerSize + (size_t)colors * 12;
    bool ok = version == 7 && depth >= 24 && bpp == 32 && byteOrder == 0 &&
              red == 0xff0000 && green == 0xff00 && blue == 0xff &&
              width > 0 && height > 0 && width <= 16384 && height <= 16384 && stride >= width * 4 &&
              pixelOffset + (size_t)stride * height <= (size_t)st.st_size;
    if (!ok) {
        os_log(OS_LOG_DEFAULT, "WXF xfce: unexpected XWD file: version %u depth %u bpp %u %ux%u stride %u masks %x/%x/%x",
               version, depth, bpp, width, height, stride, red, green, blue);
        munmap(map, (size_t)st.st_size);
        return false;
    }
    S.map = map; S.mapSize = (size_t)st.st_size;
    S.pixels = (const uint8_t *)map + pixelOffset;
    S.xWidth = width; S.xHeight = height; S.xStride = stride;
    S.shadow = malloc((size_t)stride * height);
    if (!S.shadow) { UnmapXScreen(); return false; }
    return true;
}

static void UnmapXScreen(void) {
    free(S.shadow); S.shadow = NULL;
    if (S.map) munmap(S.map, S.mapSize);
    S.map = NULL; S.pixels = NULL; S.mapSize = 0;
}

// --- Input to the X server ------------------------------------------------------------------

static void Send(const char *format, ...) {
    if (S.fifo < 0) return;
    char line[64];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(line, sizeof line, format, args);
    va_end(args);
    if (n > 0 && n < (int)sizeof line && write(S.fifo, line, (size_t)n) != n) {   // a full pipe drops the event
        static int reported;
        if (reported++ < 10) os_log(OS_LOG_DEFAULT, "WXF xfce: dropped input event %{public}s (errno %d)", line, errno);
    }
}

static void SendPointer(CGPoint location) {
    // Event locations are points; the surface is pixels (a 3600x2338 pixel mode is 1800x1169 points).
    float px = (float)((location.x - S.bounds.origin.x * S.pointWidth / S.bounds.size.width) * S.width / S.pointWidth);
    float py = (float)((location.y - S.bounds.origin.y * S.pointHeight / S.bounds.size.height) * S.height / S.pointHeight);
    gPointerX = px; gPointerY = py;
    float x = (px - S.originX) / S.scale, y = (py - S.originY) / S.scale;
    x = fminf(fmaxf(x, 0), (float)S.xWidth - 1);
    y = fminf(fmaxf(y, 0), (float)S.xHeight - 1);
    if (x == gLastSentX && y == gLastSentY) return;
    gLastSentX = x; gLastSentY = y;
    Send("m %d %d\n", (int)x, (int)y);
}

static int XButton(uint32_t button) {
    switch (button) { case 0: return 1; case 1: return 3; case 2: return 2; default: return 5 + (int)button; }
}

// Runs on WindowServer's event thread. Everything is consumed: the display is the X server's.
static WXFEventDisposition OnEvent(WXFEventRef event, void *info) {
    (void)info;
    if (!gActive) return WXFEventDispositionPass;
    switch (WXFEventGetType(event)) {
        case WXFEventTypeKeyDown:
        case WXFEventTypeKeyUp: {
            bool down = WXFEventGetType(event) == WXFEventTypeKeyDown;
            uint16_t key = WXFEventGetKeyCode(event);
            uint32_t flags = WXFEventGetFlags(event);
            if (down && key == VK_ESCAPE && (flags & (WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand)) ==
                                            (WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand)) {
                gStopRequested = 1;
                break;
            }
            Send("k %d %d\n", key, down);
            break;
        }
        case WXFEventTypeFlagsChanged: {
            uint32_t flags = WXFEventGetFlags(event), changed = flags ^ gPreviousFlags;
            gPreviousFlags = flags;
            static const struct { uint32_t flag; int key; } modifiers[] = {
                { WXFEventFlagShift, VK_SHIFT }, { WXFEventFlagControl, VK_CONTROL },
                { WXFEventFlagOption, VK_OPTION }, { WXFEventFlagCommand, VK_COMMAND },
            };
            for (size_t i = 0; i < sizeof modifiers / sizeof *modifiers; i++)
                if (changed & modifiers[i].flag) Send("k %d %d\n", modifiers[i].key, (flags & modifiers[i].flag) != 0);
            break;
        }
        case WXFEventTypeMouseMoved:
        case WXFEventTypeMouseDragged:
            SendPointer(WXFEventGetLocation(event));
            break;
        case WXFEventTypeMouseDown:
        case WXFEventTypeMouseUp:
            SendPointer(WXFEventGetLocation(event));
            Send("b %d %d\n", XButton(WXFEventGetButton(event)), WXFEventGetType(event) == WXFEventTypeMouseDown);
            {   // Clicks are rare enough to log: a release that never arrives here is the likely cause of a stuck X server.
                static int logged;
                if (logged++ < 400)
                    os_log(OS_LOG_DEFAULT, "WXF xfce: mouse %{public}s button %u at %.0f,%.0f",
                           WXFEventGetType(event) == WXFEventTypeMouseDown ? "down" : "up", WXFEventGetButton(event),
                           WXFEventGetLocation(event).x, WXFEventGetLocation(event).y);
            }
            break;
        case WXFEventTypeScrollWheel: {
            CGPoint d = WXFEventGetScrollDelta(event);
            gScrollX += d.x; gScrollY += d.y;
            while (gScrollY >= 1)  { Send("b 4 1\nb 4 0\n"); gScrollY -= 1; }
            while (gScrollY <= -1) { Send("b 5 1\nb 5 0\n"); gScrollY += 1; }
            while (gScrollX >= 1)  { Send("b 6 1\nb 6 0\n"); gScrollX -= 1; }
            while (gScrollX <= -1) { Send("b 7 1\nb 7 0\n"); gScrollX += 1; }
            break;
        }
        default:
            return WXFEventDispositionPass;
    }
    return WXFEventDispositionConsume;
}

// --- Metal ----------------------------------------------------------------------------------

static NSData *EmbeddedMetallib(void) {
    Dl_info info;
    if (!dladdr((void *)&EmbeddedMetallib, &info) || !info.dli_fbase) return nil;
    unsigned long length = 0;
    const uint8_t *bytes = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__wxf_shader", &length);
    return bytes && length ? [NSData dataWithBytes:bytes length:length] : nil;
}

static bool MapFormat(uint32_t fourCC, MTLPixelFormat *metal, uint32_t *bytesPerElement) {
    switch (fourCC) {
        case 'BGRA': *metal = MTLPixelFormatBGRA8Unorm;    *bytesPerElement = 4; return true;
        case 'RGhA': *metal = MTLPixelFormatRGBA16Float;   *bytesPerElement = 8; return true;
        case 'l10r': *metal = MTLPixelFormatBGR10A2Unorm;  *bytesPerElement = 4; return true;
        default: return false;
    }
}

static void ReleaseMetal(void) {
    for (int i = 0; i < SURFACE_COUNT; i++) {
        S.targets[i] = nil;
        if (S.surfaces[i]) { CFRelease(S.surfaces[i]); S.surfaces[i] = NULL; }
    }
    S.xTexture = nil; S.pipeline = nil; S.queue = nil; S.device = nil;
}

static bool SetupMetal(uint32_t width, uint32_t height, uint32_t fourCC) {
    MTLPixelFormat format; uint32_t bytes;
    if (!MapFormat(fourCC, &format, &bytes)) {
        os_log(OS_LOG_DEFAULT, "WXF xfce: scanout format 0x%08x is not handled, using BGRA", fourCC);
        fourCC = 'BGRA';
        MapFormat(fourCC, &format, &bytes);
    }
    S.device = MTLCreateSystemDefaultDevice();
    if (!S.device) { os_log(OS_LOG_DEFAULT, "WXF xfce: no Metal device"); return false; }
    S.queue = [S.device newCommandQueue];

    NSData *data = EmbeddedMetallib();
    if (!data) { os_log(OS_LOG_DEFAULT, "WXF xfce: no embedded metallib"); return false; }
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> library = [S.device newLibraryWithData:dd error:&error];
    if (!library) { os_log(OS_LOG_DEFAULT, "WXF xfce: metallib: %{public}@", error); return false; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.colorAttachments[0].pixelFormat = format;
    pd.vertexFunction = [library newFunctionWithName:@"xfce_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"xfce_fragment"];
    S.pipeline = [S.device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!S.pipeline) { os_log(OS_LOG_DEFAULT, "WXF xfce: pipeline: %{public}@", error); return false; }

    MTLTextureDescriptor *xd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:S.xWidth height:S.xHeight mipmapped:NO];
    xd.usage = MTLTextureUsageShaderRead;
    xd.storageMode = MTLStorageModeShared;
    S.xTexture = [S.device newTextureWithDescriptor:xd];
    if (!S.xTexture) { os_log(OS_LOG_DEFAULT, "WXF xfce: texture for the X screen failed"); return false; }

    for (int i = 0; i < SURFACE_COUNT; i++) {
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(width),
            (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @(bytes),
            (id)kIOSurfacePixelFormat: @(fourCC),
            // What WSIOSurfaceCreateWithFormatDisplayable (0x187487fcc) sets for scanout surfaces.
            @"IsDisplayable": @YES,
            (id)kIOSurfaceCacheMode: @0x700,
        };
        S.surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!S.surfaces[i]) { os_log(OS_LOG_DEFAULT, "WXF xfce: IOSurfaceCreate failed"); return false; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                      width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        S.targets[i] = [S.device newTextureWithDescriptor:td iosurface:S.surfaces[i] plane:0];
        if (!S.targets[i]) { os_log(OS_LOG_DEFAULT, "WXF xfce: texture from IOSurface failed"); return false; }
    }
    S.width = width; S.height = height; S.next = 0;
    return true;
}

// Waited for, not pipelined: presenting a frame while the next one rendered hung WindowServer's main
// thread in CubeExample (docs/display-internals.md).
static IOSurfaceRef RenderFrame(void) {
    // The X server paints into the file while this reads it, which shows as tearing. Copy it, then
    // read it again and compare: equal means nothing was painted during the copy. Up to three tries.
    size_t bytes = (size_t)S.xStride * S.xHeight;
    memcpy(S.shadow, S.pixels, bytes);
    for (int tries = 0; tries < 3 && memcmp(S.shadow, S.pixels, bytes) != 0; tries++) {
        if (tries == 0) S.changedWhileCopying++;
        memcpy(S.shadow, S.pixels, bytes);
    }
    [S.xTexture replaceRegion:MTLRegionMake2D(0, 0, S.xWidth, S.xHeight) mipmapLevel:0
                    withBytes:S.shadow bytesPerRow:S.xStride];

    unsigned i = S.next++ % SURFACE_COUNT;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = S.targets[i];
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    XfceUniforms u = {
        .screen = { (float)S.width, (float)S.height },
        .xSize = { (float)S.xWidth, (float)S.xHeight },
        .origin = { S.originX, S.originY },
        .pointer = { gPointerX, gPointerY },
        .scale = S.scale,
        .cursorScale = fmaxf(1.0f, roundf(S.scale)),
        .nearest = fabsf(S.scale - roundf(S.scale)) < 0.001f ? 1.0f : 0.0f,
        .showPointer = S.drawPointer ? 1.0f : 0.0f,
    };
    id<MTLCommandBuffer> cb = [S.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:S.pipeline];
    [enc setFragmentTexture:S.xTexture atIndex:0];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        os_log(OS_LOG_DEFAULT, "WXF xfce: GPU frame failed: %{public}@", cb.error);
        return NULL;
    }
    return S.surfaces[i];
}

// --- Pacing ---------------------------------------------------------------------------------

static double MachSeconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)ticks * tb.numer / tb.denom / 1e9;
}

// The next vblank worth aiming at (a WXFCurrentTime value), or 0 if the connector's vblank clock is
// not running. previousVBL/vblDelta are mach ticks; WXFCurrentTime is WindowServer's own clock.
static double NextVBlank(double now, double *period) {
    uint64_t previous = 0, interval = 0;
    if (!WXFCardGetVBlank(S.connector, &previous, &interval) || !previous || !interval) return 0;
    double offset = now - MachSeconds(mach_absolute_time());
    double p = MachSeconds(interval);
    double last = MachSeconds(previous) + offset;
    if (p <= 0 || now - last > VBLANK_FRESH) return 0;
    *period = p;
    return last + ceil((now + RENDER_LEAD * 0.5 - last) / p) * p;
}

// --- Run ------------------------------------------------------------------------------------

static void Tick(void *info, double now);

static void Finish(const char *why) {
    os_log(OS_LOG_DEFAULT, "WXF xfce: ending (%{public}s) after %llu frames", why, S.frames);
    if (S.intervals)
        os_log(OS_LOG_DEFAULT, "WXF xfce: timing: vblank-paced frames %llu/%llu, vblank period %.2f ms, "
               "frame interval avg %.2f max %.2f ms, max render+wait %.2f ms, max present %.2f ms",
               S.vblankFrames, S.frames, S.period * 1000, S.sumInterval / S.intervals * 1000,
               S.maxInterval * 1000, S.maxRender * 1000, S.maxPresent * 1000);
    os_log(OS_LOG_DEFAULT, "WXF xfce: the X screen was painted during the copy in %llu of %llu frames", S.changedWhileCopying, S.frames);
    gActive = 0;
    if (S.handler) { WXFEventRemoveHandler(S.handler); S.handler = WXFEventHandlerIDInvalid; }
    if (S.fifo >= 0) { close(S.fifo); S.fifo = -1; }
    WXFCardSetUpdatesDisabled(S.connector, false);
    ReleaseMetal();
    UnmapXScreen();
    S.phase = Idle;
}

static bool BeginRun(WXFConnectorID connector, bool drawPointer) {
    WXFConnectorInfo info;
    WXFScanoutInfo scanout;
    if (!WXFCardGetConnector(connector, &info) || !WXFCardGetScanout(connector, &scanout)) {
        os_log(OS_LOG_DEFAULT, "WXF xfce: connector %u has no scanout surface", connector);
        return false;
    }
    os_log(OS_LOG_DEFAULT, "WXF xfce: scanout %ux%u format 0x%08x presentFlags 0x%x, bounds %.0fx%.0f at %.0f,%.0f",
           scanout.width, scanout.height, scanout.pixelFormat, scanout.presentFlags,
           info.bounds.size.width, info.bounds.size.height, info.bounds.origin.x, info.bounds.origin.y);
    if (!MapXScreen()) return false;
    if (!SetupMetal(scanout.width, scanout.height, scanout.pixelFormat)) {
        ReleaseMetal(); UnmapXScreen();
        return false;
    }
    S.connector = connector;
    S.drawPointer = drawPointer;
    S.bounds = info.bounds;
    S.pointWidth = (float)info.bounds.size.width; S.pointHeight = (float)info.bounds.size.height;
    WXFModeInfo modes[256];
    size_t modeCount = WXFCardCopyModes(connector, modes, 256);
    for (size_t i = 0; i < modeCount && i < 256; i++)
        if (modes[i].isCurrent && modes[i].pointWidth && modes[i].pointHeight) {
            S.pointWidth = modes[i].pointWidth; S.pointHeight = modes[i].pointHeight;
        }
    os_log(OS_LOG_DEFAULT, "WXF xfce: pointer space %.0fx%.0f points", S.pointWidth, S.pointHeight);
    // The X screen is drawn at the largest size that fits the display, centred.
    S.scale = fminf((float)S.width / S.xWidth, (float)S.height / S.xHeight);
    S.originX = ((float)S.width - S.xWidth * S.scale) * 0.5f;
    S.originY = ((float)S.height - S.xHeight * S.scale) * 0.5f;
    os_log(OS_LOG_DEFAULT, "WXF xfce: X screen %ux%u on a %ux%u surface, scale %.3f", S.xWidth, S.xHeight, S.width, S.height, S.scale);

    S.fifo = open(INPUT_FIFO_PATH, O_WRONLY | O_NONBLOCK);
    if (S.fifo >= 0) fcntl(S.fifo, F_SETNOSIGPIPE, 1);
    else os_log(OS_LOG_DEFAULT, "WXF xfce: no input helper on %{public}s (errno %d): the screen will not react", INPUT_FIFO_PATH, errno);

    gPointerX = (float)S.width * 0.5f; gPointerY = (float)S.height * 0.5f;
    gStopRequested = 0; gPreviousFlags = 0; gScrollX = gScrollY = 0; gLastSentX = gLastSentY = -1;
    S.handler = WXFEventAddHandler(WXFEventTypeKey | WXFEventTypeMouse | WXFEventTypeScrollWheel, OnEvent, NULL);
    if (!S.handler) os_log(OS_LOG_DEFAULT, "WXF xfce: event handler not installed: no input");

    S.phase = Running;
    S.lastFrameAt = 0; S.period = 0;
    S.sumInterval = S.maxInterval = S.maxRender = S.maxPresent = 0;
    S.slowIntervals = S.intervals = S.vblankFrames = 0;
    S.frames = 0; S.failedFrames = 0; S.changedWhileCopying = 0;
    S.begin = WXFCurrentTime();
    S.end = S.begin + S.duration;
    gActive = 1;
    WXFCardSetUpdatesDisabled(connector, true);
    return true;
}

static void Tick(void *info, double now) {
    (void)info;
    now = WXFCurrentTime();
    if (S.phase == Idle) {
        struct timespec t;
        if (WXFCardAvailable() && TriggerTime(&t) && Newer(t, S.lastTrigger)) {
            S.lastTrigger = t;
            Request r = ReadRequest();
            if (!r.stop) {
                WXFConnectorInfo list[16];
                size_t total = WXFCardCopyConnectors(list, 16);
                const WXFConnectorInfo *pick = NULL;
                for (size_t i = 0; i < total && i < 16 && !pick; i++) {
                    const WXFConnectorInfo *c = &list[i];
                    if (!c->managed || !c->enabled || !c->hasUniqueID) continue;
                    if (r.connector >= 0 ? c->id == (WXFConnectorID)r.connector : c->type == WXFConnectorTypeInternal)
                        pick = c;
                }
                if (!pick) os_log(OS_LOG_DEFAULT, "WXF xfce: no usable connector (asked for %d)", r.connector);
                else {
                    S.duration = r.seconds;
                    os_log(OS_LOG_DEFAULT, "WXF xfce: starting on connector %u for %.0f s", pick->id, r.seconds);
                    if (BeginRun(pick->id, r.pointer)) { WXFScheduleCallback(Tick, NULL, now); return; }
                    os_log(OS_LOG_DEFAULT, "WXF xfce: could not start");
                }
            }
        }
        WXFScheduleCallback(Tick, NULL, now + 1.0);
        return;
    }

    // Running
    struct timespec t;
    if (S.frames % 30 == 0 && TriggerTime(&t) && Newer(t, S.lastTrigger)) {
        S.lastTrigger = t;
        if (ReadRequest().stop) gStopRequested = 1;
    }
    if (gStopRequested) { Finish("stop requested"); WXFScheduleCallback(Tick, NULL, now + 1.0); return; }
    if (now >= S.end)   { Finish("time is up");       WXFScheduleCallback(Tick, NULL, now + 1.0); return; }

    double period = 0;
    double target = NextVBlank(now, &period);
    if (target > 0 && target - now > RENDER_LEAD + 0.0005) {
        WXFScheduleCallback(Tick, NULL, target - RENDER_LEAD);
        return;
    }
    if (target > 0) { S.vblankFrames++; S.period = period; }
    if (S.lastFrameAt > 0) {
        double interval = now - S.lastFrameAt;
        S.intervals++;
        S.sumInterval += interval;
        if (interval > S.maxInterval) S.maxInterval = interval;
    }
    S.lastFrameAt = now;

    IOSurfaceRef frame = RenderFrame();
    double rendered = WXFCurrentTime();
    bool shown = frame && WXFCardPresentExclusive(S.connector, frame, false);
    double presented = WXFCurrentTime();
    if (rendered - now > S.maxRender) S.maxRender = rendered - now;
    if (presented - rendered > S.maxPresent) S.maxPresent = presented - rendered;

    if (shown) S.failedFrames = 0; else S.failedFrames++;
    if (S.frames < 3 || !shown) os_log(OS_LOG_DEFAULT, "WXF xfce: frame %llu presented=%d", S.frames, shown);
    S.frames++;
    if (S.failedFrames >= MAX_FAILED_FRAMES) {
        Finish("presenting keeps failing");
        WXFScheduleCallback(Tick, NULL, now + 1.0);
        return;
    }
    double after = WXFCurrentTime();
    WXFScheduleCallback(Tick, NULL, target > 0 ? fmax(target + S.period - RENDER_LEAD, after) : after + FRAME_INTERVAL);
}

// The app half. Any process but WindowServer is a Cocoa app that xfce-open.sh started for the X
// session, and its windows go on that session (XBridge.m). The bridge is its own dylib, next to this
// one in XFCEExample.support, loaded only here: it links AppKit, which this dylib must not pull into
// WindowServer. it is the XFCEBridge target, which scripts/deploy.sh builds and installs.
static void StartBridgeInApp(void) {
    if (!getenv("WXF_XBRIDGE")) return;   // the app was not started for the X session
    Dl_info info;
    if (!dladdr((void *)&StartBridgeInApp, &info) || !info.dli_fname) return;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s", info.dli_fname);
    char *slash = strrchr(path, '/');
    if (!slash) return;
    snprintf(slash, sizeof path - (size_t)(slash - path), "/XFCEExample.support/libXFCEBridge.dylib");
    void *handle = dlopen(path, RTLD_NOW);
    void (*start)(void) = handle ? (void (*)(void))dlsym(handle, "XBridgeStart") : NULL;
    if (!start) {
        os_log(OS_LOG_DEFAULT, "WXF xfce: no bridge at %{public}s (%{public}s)", path, dlerror() ?: "no XBridgeStart");
        return;
    }
    start();
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    if (WXFGetHost() != WXFHostWindowServer) {
        StartBridgeInApp();
        return;
    }
    S.fifo = -1;
    TriggerTime(&S.lastTrigger);   // a leftover trigger file must not start anything
    WXFScheduleCallback(Tick, NULL, WXFCurrentTime() + 5.0);
}
