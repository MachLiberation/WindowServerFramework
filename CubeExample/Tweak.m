//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// A Metal cube on a card0 connector (WXFCard.h). WindowServer stops drawing the connector and the
// tweak puts its own frames on it: a spinning cube rendered into IOSurfaces the size and format of
// the connector's scanout surface, shown with WXFCardPresentExclusive. Optionally it changes the
// connector's mode first (WXFCardSetMode) and puts the old mode back afterwards.
//
// Nothing happens at load. To run it, touch the trigger file from a shell:
//
//   echo "seconds=15" > /private/tmp/wxf-cube                  the internal display, as it is
//   echo "mode=66 seconds=15" > /private/tmp/wxf-cube          ... in WindowServer mode id 66
//   echo "connector=1 mode=66 seconds=15" > /private/tmp/wxf-cube
//   echo "stop" > /private/tmp/wxf-cube                         end a running cube now
//
// (CardExample logs the connector ids and mode ids.) After `seconds` (default 15, at most 120) the
// tweak turns WindowServer's drawing back on and restores the previous mode. A trigger file that is
// already there when WindowServer starts is ignored: only a changed file counts. Read the result with
//   /usr/bin/log show --last 10m --process WindowServer | grep WXF

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFCard.h>
#include <WindowServerFramework/WXFMisc.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurface.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <mach-o/getsect.h>
#include <os/log.h>
#include <simd/simd.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#define TRIGGER_PATH       "/private/tmp/wxf-cube"
#define DEFAULT_SECONDS    15.0
#define MAX_SECONDS        120.0
#define FRAME_INTERVAL     (1.0 / 60.0)    // only when the connector reports no vblank
#define RENDER_LEAD        0.0025          // seconds before a vblank that a frame is started
#define VBLANK_FRESH       0.25            // a vblank older than this is not advancing
#define SURFACE_COUNT      3
#define MODE_WAIT_SECONDS  6.0
#define MAX_FAILED_FRAMES  45

typedef struct {
    simd_float4x4 mvp;
    simd_float4x4 model;
    float time;
    float aspect;
    float padding[2];
} CubeUniforms;

typedef enum { Idle, WaitingForMode, Running } Phase;

static struct {
    Phase phase;
    WXFConnectorID connector;
    uint32_t previousMode;
    uint32_t wantedMode;          // 0 = leave the mode alone
    bool changedMode;
    double begin, end;            // WXFCurrentTime values
    double duration;              // seconds the cube runs once it is on screen
    double modeDeadline;
    int failedFrames;
    uint64_t frames;
    struct timespec lastTrigger;  // mtime of the trigger file we have handled

    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> cubePipeline, backgroundPipeline;
    id<MTLDepthStencilState> depthState;
    id<MTLTexture> depth;
    double maxGPU;                  // longest a frame took on the GPU, seconds
    IOSurfaceRef surfaces[SURFACE_COUNT];
    id<MTLTexture> targets[SURFACE_COUNT];
    unsigned next;
    uint32_t width, height;

    // Frame timing, logged when the run ends.
    double lastFrameAt;           // when the previous frame was started
    double target;                // the vblank the current frame is for (0 = free-running)
    double period;                // seconds per vblank, 0 if unknown
    double sumInterval, maxInterval, maxRender, maxPresent;
    uint64_t slowIntervals, intervals, vblankFrames;
    int outliersLogged;
} S;

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

typedef struct { int connector; int mode; double seconds; bool stop; } Request;

static Request ReadRequest(void) {
    Request r = { .connector = -1, .mode = 0, .seconds = DEFAULT_SECONDS };
    char text[256] = {0};
    FILE *f = fopen(TRIGGER_PATH, "r");
    if (f) { fread(text, 1, sizeof text - 1, f); fclose(f); }
    if (strstr(text, "stop")) r.stop = true;
    const char *p;
    if ((p = strstr(text, "connector="))) r.connector = atoi(p + 10);
    if ((p = strstr(text, "mode=")))      r.mode = atoi(p + 5);
    if ((p = strstr(text, "seconds=")))   r.seconds = atof(p + 8);
    if (r.seconds < 1) r.seconds = 1;
    if (r.seconds > MAX_SECONDS) r.seconds = MAX_SECONDS;
    return r;
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
    S.depth = nil; S.depthState = nil; S.cubePipeline = nil; S.backgroundPipeline = nil;
    S.queue = nil; S.device = nil;
}

static bool SetupMetal(uint32_t width, uint32_t height, uint32_t fourCC) {
    MTLPixelFormat format; uint32_t bytes;
    if (!MapFormat(fourCC, &format, &bytes)) {
        os_log(OS_LOG_DEFAULT, "WXF cube: scanout format 0x%08x is not handled, using BGRA", fourCC);
        fourCC = 'BGRA';
        MapFormat(fourCC, &format, &bytes);
    }
    S.device = MTLCreateSystemDefaultDevice();
    if (!S.device) {
        os_log(OS_LOG_DEFAULT, "WXF cube: no Metal device");
        return false;
    }
    S.queue = [S.device newCommandQueue];

    NSData *data = EmbeddedMetallib();
    if (!data) { os_log(OS_LOG_DEFAULT, "WXF cube: no embedded metallib"); return false; }
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> library = [S.device newLibraryWithData:dd error:&error];
    if (!library) { os_log(OS_LOG_DEFAULT, "WXF cube: metallib: %{public}@", error); return false; }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.colorAttachments[0].pixelFormat = format;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    pd.vertexFunction = [library newFunctionWithName:@"cube_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"cube_fragment"];
    S.cubePipeline = [S.device newRenderPipelineStateWithDescriptor:pd error:&error];
    pd.vertexFunction = [library newFunctionWithName:@"background_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"background_fragment"];
    id<MTLRenderPipelineState> bg = [S.device newRenderPipelineStateWithDescriptor:pd error:&error];
    S.backgroundPipeline = bg;
    if (!S.cubePipeline || !S.backgroundPipeline) {
        os_log(OS_LOG_DEFAULT, "WXF cube: pipeline: %{public}@", error);
        return false;
    }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    S.depthState = [S.device newDepthStencilStateWithDescriptor:dsd];

    MTLTextureDescriptor *dtd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                    width:width height:height mipmapped:NO];
    dtd.usage = MTLTextureUsageRenderTarget;
    dtd.storageMode = MTLStorageModePrivate;
    S.depth = [S.device newTextureWithDescriptor:dtd];

    for (int i = 0; i < SURFACE_COUNT; i++) {
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(width),
            (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @(bytes),
            (id)kIOSurfacePixelFormat: @(fourCC),
            // What WSIOSurfaceCreateWithFormatDisplayable (0x187487fcc) sets for scanout surfaces; the
            // direct present hands the surface to IOMobileFramebuffer as layer 0, which needs both.
            @"IsDisplayable": @YES,
            (id)kIOSurfaceCacheMode: @0x700,
        };
        S.surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!S.surfaces[i]) { os_log(OS_LOG_DEFAULT, "WXF cube: IOSurfaceCreate failed"); return false; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                      width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        S.targets[i] = [S.device newTextureWithDescriptor:td iosurface:S.surfaces[i] plane:0];
        if (!S.targets[i]) { os_log(OS_LOG_DEFAULT, "WXF cube: texture from IOSurface failed"); return false; }
    }
    S.width = width; S.height = height; S.next = 0;
    return true;
}

static simd_float4x4 Perspective(float fovy, float aspect, float zn, float zf) {
    float f = 1.0f / tanf(fovy * 0.5f);
    return (simd_float4x4){{
        { f / aspect, 0, 0, 0 },
        { 0, f, 0, 0 },
        { 0, 0, zf / (zn - zf), -1 },
        { 0, 0, zn * zf / (zn - zf), 0 },
    }};
}

static simd_float4x4 Translate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (simd_float4){ x, y, z, 1 };
    return m;
}

static simd_float4x4 Rotate(float angle, simd_float3 axis) {
    axis = simd_normalize(axis);
    float c = cosf(angle), s = sinf(angle), t = 1 - c;
    float x = axis.x, y = axis.y, z = axis.z;
    return (simd_float4x4){{
        { t*x*x + c,   t*x*y + z*s, t*x*z - y*s, 0 },
        { t*x*y - z*s, t*y*y + c,   t*y*z + x*s, 0 },
        { t*x*z + y*s, t*y*z - x*s, t*z*z + c,   0 },
        { 0, 0, 0, 1 },
    }};
}

// Renders one frame into the next surface and returns it (still owned by S), or NULL.
static IOSurfaceRef RenderFrame(double seconds) {
    unsigned i = S.next++ % SURFACE_COUNT;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = S.targets[i];
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = S.depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    float aspect = (float)S.width / (float)S.height;
    float t = (float)seconds;
    simd_float4x4 model = simd_mul(Rotate(t * 0.9f, (simd_float3){ 0, 1, 0 }), Rotate(0.5f + t * 0.55f, (simd_float3){ 1, 0, 0 }));
    float scale = aspect >= 1 ? 1 : aspect;   // keep it on screen on a tall display
    simd_float4x4 view = Translate(0, 0, -5.0f / scale);
    CubeUniforms u = {
        .mvp = simd_mul(Perspective(0.9f, aspect, 0.1f, 50.0f), simd_mul(view, model)),
        .model = model,
        .time = t,
        .aspect = aspect,
    };

    id<MTLCommandBuffer> cb = [S.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:S.backgroundPipeline];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc setRenderPipelineState:S.cubePipeline];
    [enc setDepthStencilState:S.depthState];
    [enc setVertexBytes:&u length:sizeof u atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];
    [enc endEncoding];
    [cb commit];

    // Waited for: an attempt to present the previous frame while this one rendered hung
    // WindowServer's main thread on the third present (2026-10-28), so a frame is finished before
    // it is shown, at the cost of the main thread sitting on the GPU for a frame's duration.
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        os_log(OS_LOG_DEFAULT, "WXF cube: GPU frame failed: %{public}@", cb.error);
        return NULL;
    }
    double gpu = cb.GPUEndTime - cb.GPUStartTime;
    if (gpu > S.maxGPU) S.maxGPU = gpu;
    return S.surfaces[i];
}

// --- Pacing ---------------------------------------------------------------------------------

static double MachSeconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)ticks * tb.numer / tb.denom / 1e9;
}

// The next vblank worth aiming at (a WXFCurrentTime value), or 0 if the connector's vblank clock is
// not running. CAWindowServerDisplay's previousVBL/vblDelta are mach ticks; WXFCurrentTime is
// WindowServer's own clock, so the two are lined up with a sample of each.
static double NextVBlank(double now, double *period) {
    uint64_t previous = 0, interval = 0;
    if (!WXFCardGetVBlank(S.connector, &previous, &interval) || !previous || !interval) return 0;
    double offset = now - MachSeconds(mach_absolute_time());
    double p = MachSeconds(interval);
    double last = MachSeconds(previous) + offset;
    if (p <= 0 || now - last > VBLANK_FRESH) return 0;
    *period = p;
    // Half the lead of slack: waking a little after the planned start still catches this vblank.
    return last + ceil((now + RENDER_LEAD * 0.5 - last) / p) * p;
}

// --- Run ------------------------------------------------------------------------------------

static void Tick(void *info, double now);

static void Finish(const char *why) {
    os_log(OS_LOG_DEFAULT, "WXF cube: ending (%{public}s) after %llu frames", why, S.frames);
    if (S.intervals)
        os_log(OS_LOG_DEFAULT, "WXF cube: timing: vblank-paced frames %llu/%llu, vblank period %.2f ms, "
               "frame interval avg %.2f max %.2f ms, %llu intervals over 1.5 periods (or 25 ms), "
               "max render+wait %.2f ms, max present %.2f ms, max GPU %.2f ms",
               S.vblankFrames, S.frames, S.period * 1000, S.sumInterval / S.intervals * 1000,
               S.maxInterval * 1000, S.slowIntervals, S.maxRender * 1000, S.maxPresent * 1000, S.maxGPU * 1000);
    WXFCardSetUpdatesDisabled(S.connector, false);
    ReleaseMetal();
    if (S.changedMode) {
        bool ok = WXFCardSetMode(S.connector, S.previousMode);
        os_log(OS_LOG_DEFAULT, "WXF cube: restoring mode %u: %{public}s", S.previousMode, ok ? "requested" : "refused");
    }
    S.phase = Idle;
}

static bool BeginRun(void) {
    WXFScanoutInfo scanout;
    if (!WXFCardGetScanout(S.connector, &scanout)) return false;
    os_log(OS_LOG_DEFAULT, "WXF cube: scanout %ux%u format 0x%08x framebufferFormat %u presentFlags 0x%x",
           scanout.width, scanout.height, scanout.pixelFormat, scanout.framebufferFormat, scanout.presentFlags);
    if (!SetupMetal(scanout.width, scanout.height, scanout.pixelFormat)) {
        ReleaseMetal();
        return false;
    }
    S.phase = Running;
    S.lastFrameAt = 0; S.target = 0; S.period = 0;
    S.sumInterval = S.maxInterval = S.maxRender = S.maxPresent = 0;
    S.slowIntervals = S.intervals = S.vblankFrames = 0;
    S.outliersLogged = 0;
    S.maxGPU = 0;
    S.frames = 0;
    S.failedFrames = 0;
    S.begin = WXFCurrentTime();
    S.end = S.begin + S.duration;
    WXFCardSetUpdatesDisabled(S.connector, true);
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
            if (r.stop) { WXFScheduleCallback(Tick, NULL, now + 1.0); return; }

            WXFConnectorInfo list[16];
            size_t total = WXFCardCopyConnectors(list, 16);
            const WXFConnectorInfo *pick = NULL;
            for (size_t i = 0; i < total && i < 16 && !pick; i++) {
                const WXFConnectorInfo *c = &list[i];
                if (!c->managed || !c->enabled || !c->hasUniqueID) continue;
                if (r.connector >= 0 ? c->id == (WXFConnectorID)r.connector : c->type == WXFConnectorTypeInternal)
                    pick = c;
            }
            if (!pick) {
                os_log(OS_LOG_DEFAULT, "WXF cube: no usable connector (asked for %d)", r.connector);
            } else {
                S.connector = pick->id;
                S.previousMode = pick->currentModeID;
                S.wantedMode = (uint32_t)r.mode;
                S.changedMode = false;
                S.duration = r.seconds;
                os_log(OS_LOG_DEFAULT, "WXF cube: starting on connector %u (mode %u, wanted %u), %.0f s",
                       S.connector, S.previousMode, S.wantedMode, r.seconds);
                if (S.wantedMode && S.wantedMode != S.previousMode) {
                    if (!WXFCardSetMode(S.connector, S.wantedMode)) {
                        os_log(OS_LOG_DEFAULT, "WXF cube: modeset to %u refused", S.wantedMode);
                        WXFScheduleCallback(Tick, NULL, now + 1.0);
                        return;
                    }
                    S.changedMode = true;
                    S.phase = WaitingForMode;
                    S.modeDeadline = now + MODE_WAIT_SECONDS;
                } else {
                    S.phase = WaitingForMode;
                    S.modeDeadline = now + MODE_WAIT_SECONDS;
                }
                WXFScheduleCallback(Tick, NULL, now + 0.25);
                return;
            }
        }
        WXFScheduleCallback(Tick, NULL, now + 1.0);
        return;
    }

    if (S.phase == WaitingForMode) {
        WXFConnectorInfo c;
        bool ready = WXFCardGetConnector(S.connector, &c) &&
                     (!S.changedMode || c.currentModeID == S.wantedMode);
        if (ready && BeginRun()) {
            os_log(OS_LOG_DEFAULT, "WXF cube: running %ux%u", S.width, S.height);
            WXFScheduleCallback(Tick, NULL, now);
            return;
        }
        if (now > S.modeDeadline) {
            os_log(OS_LOG_DEFAULT, "WXF cube: connector not ready in time (ready=%d)", ready);
            if (S.changedMode) WXFCardSetMode(S.connector, S.previousMode);
            S.phase = Idle;
            WXFScheduleCallback(Tick, NULL, now + 1.0);
            return;
        }
        WXFScheduleCallback(Tick, NULL, now + 0.25);
        return;
    }

    // Running
    struct timespec t;
    if (S.frames % 30 == 0 && TriggerTime(&t) && Newer(t, S.lastTrigger)) {
        S.lastTrigger = t;
        if (ReadRequest().stop) { Finish("stop requested"); WXFScheduleCallback(Tick, NULL, now + 1.0); return; }
    }
    if (now >= S.end) { Finish("time is up"); WXFScheduleCallback(Tick, NULL, now + 1.0); return; }

    // Frames are started shortly before a vblank and animate to that vblank's time, so a frame is on
    // screen for the same number of vblanks every time.
    double period = 0;
    double target = NextVBlank(now, &period);
    if (target > 0 && target - now > RENDER_LEAD + 0.0005) {
        WXFScheduleCallback(Tick, NULL, target - RENDER_LEAD);   // too early for this vblank
        return;
    }
    double frameTime = target > 0 ? target : now;
    if (target > 0) { S.vblankFrames++; S.period = period; }

    if (S.lastFrameAt > 0) {
        double interval = now - S.lastFrameAt;
        S.intervals++;
        S.sumInterval += interval;
        if (interval > S.maxInterval) S.maxInterval = interval;
        double slow = S.period > 0 ? 1.5 * S.period : 0.025;
        if (interval > slow) S.slowIntervals++;
        if (interval > 2.5 * (S.period > 0 ? S.period : FRAME_INTERVAL) && S.outliersLogged++ < 15)
            os_log(OS_LOG_DEFAULT, "WXF cube: frame %llu came %.1f ms after the last", S.frames, interval * 1000);
    }
    S.lastFrameAt = now;

    IOSurfaceRef frame = RenderFrame(frameTime - S.begin);
    double rendered = WXFCurrentTime();
    bool shown = frame && WXFCardPresentExclusive(S.connector, frame, false);
    double presented = WXFCurrentTime();
    if (rendered - now > S.maxRender) S.maxRender = rendered - now;
    if (presented - rendered > S.maxPresent) S.maxPresent = presented - rendered;

    if (shown) S.failedFrames = 0; else S.failedFrames++;
    if (S.frames < 3 || !shown)
        os_log(OS_LOG_DEFAULT, "WXF cube: frame %llu presented=%d", S.frames, shown);
    S.frames++;
    if (S.failedFrames >= MAX_FAILED_FRAMES) {
        Finish("presenting keeps failing");
        WXFScheduleCallback(Tick, NULL, now + 1.0);
        return;
    }
    double after = WXFCurrentTime();
    // The start of the frame for the vblank after this one.
    WXFScheduleCallback(Tick, NULL, target > 0 ? fmax(target + S.period - RENDER_LEAD, after) : after + FRAME_INTERVAL);
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    // A trigger file left over from before WindowServer started must not start anything.
    TriggerTime(&S.lastTrigger);
    WXFScheduleCallback(Tick, NULL, WXFCurrentTime() + 5.0);
}
