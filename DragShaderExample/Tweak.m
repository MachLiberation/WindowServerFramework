//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/26/26.
//

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFDrag.h>
#include <math.h>
#include <string.h>

// The wobbly model of compiz-windows-effect (Novell / hermes83), on a 16x16 grid of masses joined by
// structural and shear springs. The points under the cursor when the drag starts are held and follow
// the window; the rest lag, stretch and ring. The shader receives the grid as offsets from rest.
enum { kGrid = 16, kPoints = kGrid * kGrid };
_Static_assert(2 * kPoints == WXF_DRAG_SHADER_DATA_COUNT,
               "Raise WXF_DRAG_SHADER_DATA_COUNT to at least 2 * 16 * 16 = 512 floats");

// A finer mesh needs stiffer springs to keep the same overall feel (the chain is 5x longer), and a
// smaller time step to stay stable. Friction is a little lower and kBoost a little higher than before,
// so the effect rings longer and stretches further.
static const double kFriction = 3.0;
static const double kSpringK  = 95.0;
static const double kShearK   = 95.0 * 0.5;
static const double kMass     = 16.0;
static const double kDt       = 0.2;        // sub-step, in compiz steps
static const double kMsPerStep = 12.0;      // compiz's "speedup" divider
static const double kBoost    = 1.3;        // overall exaggeration of the offsets
static const int    kGrabRadius = 1;        // held patch is (2r+1)^2 nodes around the cursor
static const float  kMargin   = 200;        // room for the stretch, points per side

typedef struct { double x, y, vx, vy, fx, fy; bool immobile; } Mass;
static struct {
    Mass m[kPoints];
    CGPoint origin;        // the window's frame origin when last seen
    double last;           // elapsed time at the previous frame
    double acc;            // leftover fraction of a sub-step
    bool ready;
} gModel;

static inline void Spring(Mass *a, Mass *b, double rx, double ry, double k) {
    const double fx = k * (b->x - a->x - rx), fy = k * (b->y - a->y - ry);
    a->fx += fx; b->fx -= fx;
    a->fy += fy; b->fy -= fy;
}

static void Step(double steps, double w, double h) {
    const double hpad = w / (kGrid - 1), vpad = h / (kGrid - 1);
    gModel.acc += steps / kDt;
    int n = (int)gModel.acc;
    gModel.acc -= n;
    if (n > 60) { n = 60; gModel.acc = 0; }   // don't spiral after a hitch

    while (n-- > 0) {
        for (int y = 0; y < kGrid; y++) {
            for (int x = 0; x < kGrid; x++) {
                Mass *b = &gModel.m[y * kGrid + x];
                if (x > 0)                 Spring(b - 1,         b,  hpad, 0,    kSpringK);
                if (y > 0)                 Spring(b - kGrid,     b,  0,    vpad, kSpringK);
                if (x > 0 && y > 0)        Spring(b - kGrid - 1, b,  hpad, vpad, kShearK);
                if (x < kGrid - 1 && y > 0) Spring(b - kGrid + 1, b, -hpad, vpad, kShearK);
            }
        }
        for (int i = 0; i < kPoints; i++) {
            Mass *o = &gModel.m[i];
            if (!o->immobile) {
                o->fx -= kFriction * o->vx;
                o->fy -= kFriction * o->vy;
                o->vx += o->fx / kMass * kDt;
                o->vy += o->fy / kMass * kDt;
                o->x += o->vx * kDt;
                o->y += o->vy * kDt;
            }
            o->fx = o->fy = 0;
        }
    }
}

// Squeezes an offset so the control point can't leave the overlay, so a hard stretch isn't cut off.
static double Limit(double d, double lo, double hi) {
    double bound = d >= 0 ? hi : -lo;
    if (bound <= 1) return 0;
    double knee = bound * 0.6, a = fabs(d);
    if (a > knee) a = knee + (bound - knee) * tanh((a - knee) / (bound - knee));
    return d >= 0 ? a : -a;
}

static bool JelloParams(const WXFDragFrame *f, float out[WXF_DRAG_SHADER_DATA_COUNT], void *userInfo) {
    const double w = f->frame.size.width, h = f->frame.size.height;
    if (!gModel.ready || f->elapsed < gModel.last) {   // a new drag
        memset(&gModel, 0, sizeof gModel);
        for (int y = 0; y < kGrid; y++)
            for (int x = 0; x < kGrid; x++) {
                gModel.m[y * kGrid + x].x = f->frame.origin.x + x * w / (kGrid - 1);
                gModel.m[y * kGrid + x].y = f->frame.origin.y + y * h / (kGrid - 1);
            }
        // Hold the patch nearest the cursor (the middle of the top edge if it can't be read).
        const double cx = f->cursorValid ? f->cursor.x : f->frame.origin.x + w * 0.5;
        const double cy = f->cursorValid ? f->cursor.y : f->frame.origin.y + h * 0.1;
        double best = 1e30;
        int grab = 0;
        for (int i = 0; i < kPoints; i++) {
            double d = fabs(gModel.m[i].x - cx) + fabs(gModel.m[i].y - cy);
            if (d < best) { best = d; grab = i; }
        }
        const int gx = grab % kGrid, gy = grab / kGrid;
        for (int y = 0; y < kGrid; y++)
            for (int x = 0; x < kGrid; x++)
                if (abs(x - gx) <= kGrabRadius && abs(y - gy) <= kGrabRadius)
                    gModel.m[y * kGrid + x].immobile = true;
        gModel.origin = f->frame.origin;
        gModel.last = f->elapsed;
        gModel.ready = true;
    }

    // The held nodes ride along with the window.
    const double mx = f->frame.origin.x - gModel.origin.x, my = f->frame.origin.y - gModel.origin.y;
    for (int i = 0; i < kPoints; i++)
        if (gModel.m[i].immobile) { gModel.m[i].x += mx; gModel.m[i].y += my; }
    gModel.origin = f->frame.origin;

    Step((f->elapsed - gModel.last) * 1000.0 / kMsPerStep, w, h);
    gModel.last = f->elapsed;

    const double k = kBoost * f->intensity / 100.0, room = kMargin - 3;
    bool moving = false;
    for (int y = 0; y < kGrid; y++) {
        for (int x = 0; x < kGrid; x++) {
            const Mass *o = &gModel.m[y * kGrid + x];
            const double rx = x * w / (kGrid - 1), ry = y * h / (kGrid - 1);
            const double rawx = o->x - f->frame.origin.x - rx, rawy = o->y - f->frame.origin.y - ry;
            const int i = 2 * (y * kGrid + x);
            out[i]     = (float)Limit(rawx * k, -room - rx, w + room - rx);
            out[i + 1] = (float)Limit(rawy * k, -room - ry, h + room - ry);
            // Settled once nothing is still moving or displaced by more than a fraction of a point.
            if (!o->immobile && (fabs(o->vx) > 0.02 || fabs(o->vy) > 0.02 || fabs(rawx) > 0.1 || fabs(rawy) > 0.1))
                moving = true;
        }
    }
    return moving;
}

// Ammonia calls this right after the tweak is loaded into WindowServer, handing over its Gum
// interceptor. SetupFramework must run before any hook-installing call in the framework.
__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    // Every window drag is drawn through wxf_example_jello, from the metallib this dylib embeds.
    static const WXFDragShaderDescriptor jello = {
        .fragment = "wxf_example_jello",
        .params = JelloParams,
        .margin = kMargin,                 // room for the stretch
        .durationNanoseconds = 120e6f,     // minimum linger after release; the springs settle on their own
    };
    WXFDragInstallShader(&jello);
}
