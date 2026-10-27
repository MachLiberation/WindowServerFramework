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

// The wobbly model of compiz-windows-effect (Novell / hermes83): a 4x4 grid of masses joined by
// springs. The point under the cursor when the drag starts is held and follows the window; the
// rest lag, stretch and ring. The shader receives the grid as offsets from its rest positions.
enum { kGrid = 4, kPoints = kGrid * kGrid };
static const double kFriction = 3.5, kSpringK = 3.8 * 0.5, kMass = 100.0 - 70.0;
static const double kMsPerStep = 12.0;      // compiz's "speedup" divider
static const float kMargin = 170;           // room for the stretch, points per side

typedef struct { double x, y, vx, vy, fx, fy; bool immobile; } Mass;
static struct {
    Mass m[kPoints];
    int grab;
    CGPoint origin;        // the window's frame origin when last seen
    double last;           // elapsed time at the previous frame
    bool ready;
} gModel;

static void Step(double steps, double w, double h) {
    const double hpad = w / (kGrid - 1), vpad = h / (kGrid - 1);
    for (int j = (int)steps; j >= 0; j--) {
        for (int y = 0; y < kGrid; y++) {
            for (int x = 0; x < kGrid; x++) {
                Mass *b = &gModel.m[y * kGrid + x];
                if (x > 0) {
                    Mass *a = b - 1;
                    double f = kSpringK * (b->x - a->x - hpad);
                    a->fx += f; b->fx -= f;
                    f = kSpringK * (b->y - a->y);
                    a->fy += f; b->fy -= f;
                }
                if (y > 0) {
                    Mass *a = b - kGrid;
                    double f = kSpringK * (b->x - a->x);
                    a->fx += f; b->fx -= f;
                    f = kSpringK * (b->y - a->y - vpad);
                    a->fy += f; b->fy -= f;
                }
            }
        }
        for (int i = 0; i < kPoints; i++) {
            Mass *o = &gModel.m[i];
            if (o->immobile) continue;
            o->fx -= kFriction * o->vx;
            o->fy -= kFriction * o->vy;
            o->vx += o->fx / kMass;
            o->vy += o->fy / kMass;
            o->x += o->vx;
            o->y += o->vy;
            o->fx = o->fy = 0;
        }
        for (int i = 0; i < kPoints; i++) gModel.m[i].fx = gModel.m[i].fy = 0;
    }
}

// Squeezes an offset so the control point can't leave the overlay (a Bezier patch stays inside
// its control points' hull, so this is what keeps a hard stretch from being cut off).
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
        // Hold the point nearest the cursor (the middle of the top edge if it can't be read).
        const double cx = f->cursorValid ? f->cursor.x : f->frame.origin.x + w * 0.5;
        const double cy = f->cursorValid ? f->cursor.y : f->frame.origin.y + h * 0.1;
        double best = 1e30;
        for (int i = 0; i < kPoints; i++) {
            double d = fabs(gModel.m[i].x - cx) + fabs(gModel.m[i].y - cy);
            if (d < best) { best = d; gModel.grab = i; }
        }
        gModel.m[gModel.grab].immobile = true;
        gModel.origin = f->frame.origin;
        gModel.last = f->elapsed;
        gModel.ready = true;
    }

    // The held point rides along with the window.
    gModel.m[gModel.grab].x += f->frame.origin.x - gModel.origin.x;
    gModel.m[gModel.grab].y += f->frame.origin.y - gModel.origin.y;
    gModel.origin = f->frame.origin;

    Step((f->elapsed - gModel.last) * 1000.0 / kMsPerStep, w, h);
    gModel.last = f->elapsed;

    const double k = f->intensity / 100.0, room = kMargin - 3;
    bool moving = false;
    for (int y = 0; y < kGrid; y++) {
        for (int x = 0; x < kGrid; x++) {
            const Mass *o = &gModel.m[y * kGrid + x];
            const double rx = x * w / (kGrid - 1), ry = y * h / (kGrid - 1);
            const double dx = (o->x - f->frame.origin.x - rx) * k, dy = (o->y - f->frame.origin.y - ry) * k;
            const int i = 2 * (y * kGrid + x);
            out[i]     = (float)Limit(dx, -room - rx, w + room - rx);
            out[i + 1] = (float)Limit(dy, -room - ry, h + room - ry);
            // Compiz stops when no mass is being pushed by more than a point of force.
            if (!o->immobile && (fabs(o->vx) * kFriction > 1 || fabs(dx) * kSpringK * 2 > 1 || fabs(dy) * kSpringK * 2 > 1))
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
