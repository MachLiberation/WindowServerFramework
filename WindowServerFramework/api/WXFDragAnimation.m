//Created by bedtime on 10/26/26.

#include <WindowServerFramework/WXFDragAnimation.h>
#include <WindowServerFramework/WXFDrag.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include "WXFBase-Private.h"
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct __WXFDragAnimation {
    WXFBase base;
    float duration_nanoseconds;
    WXFDragAnimationEasing easing;
    float delay_nanoseconds;
    float intensity;
    float margin;
    void *shader_bytes;
    size_t shader_length;
    char *shader_fragment;
    WXFDragShaderParamFunction shader_params;
    void *shader_info;
};

static void DragAnimationDestroy(WXFTypeRef obj) {
    struct __WXFDragAnimation *a = (struct __WXFDragAnimation *)obj;
    free(a->shader_bytes);
    free(a->shader_fragment);
}

static const WXFClass kDragAnimationClass = {
    .name = "WXFDragAnimation",
    .destructor = DragAnimationDestroy,
    .equal = NULL,
};

static WXFTypeID gDragAnimationTypeID = WXFTypeIDInvalid;
static pthread_once_t gDragAnimationOnce = PTHREAD_ONCE_INIT;

static void RegisterDragAnimationClass(void) {
    gDragAnimationTypeID = WXFRegisterClass(&kDragAnimationClass);
}

WXFTypeID WXFDragAnimationGetTypeID(void) {
    pthread_once(&gDragAnimationOnce, RegisterDragAnimationClass);
    return gDragAnimationTypeID;
}

WXFDragAnimationRef WXFDragAnimationCreate(void) {
    struct __WXFDragAnimation *a =
        (struct __WXFDragAnimation *)WXFCreateInstance(WXFDragAnimationGetTypeID(), sizeof *a);
    if (!a)
        return NULL;

    a->duration_nanoseconds = 150e6f;
    a->easing = WXFDragAnimationEasingEaseInEaseOut;
    a->intensity = 100.0f;

    return a;
}

bool WXFDragAnimationSetShader(WXFDragAnimationRef animation, const void *metallib, size_t length,
                               const char *fragmentName, WXFDragShaderParamFunction params,
                               void *userInfo) {
    if (!animation || !metallib || !length || !fragmentName || !*fragmentName)
        return false;
    void *bytes = malloc(length);
    char *name = strdup(fragmentName);
    if (!bytes || !name) {
        free(bytes);
        free(name);
        return false;
    }
    memcpy(bytes, metallib, length);
    free(animation->shader_bytes);
    free(animation->shader_fragment);
    animation->shader_bytes = bytes;
    animation->shader_length = length;
    animation->shader_fragment = name;
    animation->shader_params = params;
    animation->shader_info = userInfo;
    return true;
}

bool WXFDragAnimationSetShaderFile(WXFDragAnimationRef animation, const char *path,
                                   const char *fragmentName, WXFDragShaderParamFunction params,
                                   void *userInfo) {
    if (!animation || !path)
        return false;
    FILE *f = fopen(path, "rb");
    if (!f)
        return false;
    bool ok = false;
    long size;
    void *bytes = NULL;
    if (fseek(f, 0, SEEK_END) == 0 && (size = ftell(f)) > 0 && fseek(f, 0, SEEK_SET) == 0 &&
        (bytes = malloc((size_t)size)) != NULL && fread(bytes, 1, (size_t)size, f) == (size_t)size)
        ok = WXFDragAnimationSetShader(animation, bytes, (size_t)size, fragmentName, params, userInfo);
    free(bytes);
    fclose(f);
    return ok;
}

bool WXFDragAnimationGetShader(WXFDragAnimationRef animation, const void **metallib, size_t *length,
                               const char **fragmentName, WXFDragShaderParamFunction *params,
                               void **userInfo) {
    if (!animation || !animation->shader_bytes)
        return false;
    if (metallib) *metallib = animation->shader_bytes;
    if (length) *length = animation->shader_length;
    if (fragmentName) *fragmentName = animation->shader_fragment;
    if (params) *params = animation->shader_params;
    if (userInfo) *userInfo = animation->shader_info;
    return true;
}

bool WXFDragAnimationSetDuration(WXFDragAnimationRef animation, float nanoseconds) {
    if (!animation || !(nanoseconds > 0))
        return false;
    animation->duration_nanoseconds = nanoseconds;
    return true;
}

float WXFDragAnimationGetDuration(WXFDragAnimationRef animation) {
    return animation->duration_nanoseconds;
}

bool WXFDragAnimationSetEasing(WXFDragAnimationRef animation, WXFDragAnimationEasing easing) {
    if (!animation || easing > WXFDragAnimationEasingLinear)
        return false;
    animation->easing = easing;
    return true;
}

WXFDragAnimationEasing WXFDragAnimationGetEasing(WXFDragAnimationRef animation) {
    return animation->easing;
}

bool WXFDragAnimationSetDelay(WXFDragAnimationRef animation, float nanoseconds) {
    if (!animation || !(nanoseconds >= 0))
        return false;
    animation->delay_nanoseconds = nanoseconds;
    return true;
}

float WXFDragAnimationGetDelay(WXFDragAnimationRef animation) {
    return animation->delay_nanoseconds;
}

bool WXFDragAnimationSetMargin(WXFDragAnimationRef animation, float points) {
    if (!animation || !(points >= 0) || points > 2000)
        return false;
    animation->margin = points;
    return true;
}

float WXFDragAnimationGetMargin(WXFDragAnimationRef animation) {
    return animation->margin;
}

bool WXFDragAnimationSetIntensity(WXFDragAnimationRef animation, float intensity) {
    if (!animation || !(intensity >= 0))
        return false;
    animation->intensity = intensity;
    return true;
}

float WXFDragAnimationGetIntensity(WXFDragAnimationRef animation) {
    return animation->intensity;
}

float WXFDragAnimationEvaluateEasing(WXFDragAnimationRef animation, float t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1.0f;
    switch (animation->easing) {
        case WXFDragAnimationEasingLinear:
            return t;
        case WXFDragAnimationEasingSpring:
            return 1.0f - expf(-6.0f * t) * cosf(10.0f * t);
        case WXFDragAnimationEasingEaseInEaseOut:
        default:
            return t * t * (3.0f - 2.0f * t);
    }
}

// ---------------------------------------------------------------------------------------------
// Embedded libraries and one-call setup

static const void *EmbeddedLibrary(const void *callerAddress, size_t *size) {
    Dl_info di;
    if (!dladdr(callerAddress, &di) || !di.dli_fbase)
        return NULL;
    unsigned long length = 0;
    const uint8_t *bytes = getsectiondata((const struct mach_header_64 *)di.dli_fbase,
                                          "__DATA", "__wxf_shader", &length);
    if (!bytes || !length)
        return NULL;
    *size = length;
    return bytes;
}

bool WXFDragAnimationSetEmbeddedShader(WXFDragAnimationRef animation, const char *fragmentName,
                                       WXFDragShaderParamFunction params, void *userInfo) {
    size_t size = 0;
    const void *lib = EmbeddedLibrary(__builtin_return_address(0), &size);
    return lib && WXFDragAnimationSetShader(animation, lib, size, fragmentName, params, userInfo);
}

typedef struct {
    WXFDragShaderDescriptor descriptor;
    void *library;
    size_t librarySize;
} InstalledShader;

static void ApplyInstalledShader(WXFDragContextRef context, void *userInfo) {
    const InstalledShader *s = userInfo;
    WXFDragAnimationRef animation = WXFDragAnimationCreate();
    if (!animation)
        return;
    if (WXFDragAnimationSetShader(animation, s->library, s->librarySize, s->descriptor.fragment,
                                  s->descriptor.params, s->descriptor.userInfo)) {
        WXFDragAnimationSetMargin(animation, s->descriptor.margin);
        if (s->descriptor.durationNanoseconds > 0)
            WXFDragAnimationSetDuration(animation, s->descriptor.durationNanoseconds);
        WXFDragAnimationSetEasing(animation, s->descriptor.easing);
        WXFDragContextSetAnimation(context, animation);
    }
    WXFRelease(animation);
}

WXFDragObserverID WXFDragInstallShader(const WXFDragShaderDescriptor *descriptor) {
    if (!descriptor || !descriptor->fragment || !*descriptor->fragment)
        return WXFDragObserverIDInvalid;
    size_t size = 0;
    const void *lib = EmbeddedLibrary(__builtin_return_address(0), &size);
    if (!lib)
        return WXFDragObserverIDInvalid;

    InstalledShader *s = calloc(1, sizeof *s);   // lives as long as the observer
    if (!s)
        return WXFDragObserverIDInvalid;
    s->descriptor = *descriptor;
    s->descriptor.fragment = strdup(descriptor->fragment);
    s->library = malloc(size);
    if (!s->library || !s->descriptor.fragment) {
        free(s->library);
        free((void *)s->descriptor.fragment);
        free(s);
        return WXFDragObserverIDInvalid;
    }
    memcpy(s->library, lib, size);
    s->librarySize = size;
    return WXFDragAddObserver(WXFDragPhaseBegin, ApplyInstalledShader, s);
}
