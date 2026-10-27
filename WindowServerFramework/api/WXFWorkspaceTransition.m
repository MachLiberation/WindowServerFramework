//Created by Salty on 10/26/26.

#include <WindowServerFramework/WXFWorkspaceTransition.h>
#include "WXFBase-Private.h"
#include <pthread.h>

struct __WXFWorkspaceTransition {
    WXFBase base;
    WXFTransitionEffect effect;
    float duration_nanoseconds;
    WXFTransitionEasingMode ease_mode;
    float delay_nanoseconds;
    bool enabled;
    WXFTransitionDirection direction;
    float intensity;
};

static void destructor(WXFTypeRef ref){
    struct __WXFWorkspaceTransition *obj = (struct __WXFWorkspaceTransition *)ref;
    
    if (obj->enabled){
        WXFWorkspaceTransitionSetEnabled(obj,
                                         false);
    }
}

static const WXFClass kWorkspaceTransitionClass = {
    .name = "WXFWorkspaceTransition",
    .destructor = destructor,
    .equal = NULL,
};

static WXFTypeID gWorkspaceTransitionTypeID = WXFTypeIDInvalid;
static pthread_once_t gWorkspaceTransitionOnce = PTHREAD_ONCE_INIT;

static void RegisterWorkspaceTransitionClass(void) {
    gWorkspaceTransitionTypeID = WXFRegisterClass(&kWorkspaceTransitionClass);
}

WXFTypeID WXFWorkspaceTransitionGetTypeID(void) {
    pthread_once(&gWorkspaceTransitionOnce, RegisterWorkspaceTransitionClass);
    return gWorkspaceTransitionTypeID;
}

WXFWorkspaceTransitionRef WXFWorkspaceTransitionCreate(void) {
    struct __WXFWorkspaceTransition *t =
        (struct __WXFWorkspaceTransition *)WXFCreateInstance(WXFWorkspaceTransitionGetTypeID(),
                                                             sizeof *t);
    if (!t)
        return NULL;
    
    t->effect = WXFTransitionEffectSlide;
    
    return t;
}

bool WXFWorkspaceTransitionSetEffect(WXFWorkspaceTransitionRef transition,
                                     WXFTransitionEffect effect) {
    if (!transition || effect > WXFTransitionEffectImmediate)
        return false;
    
    transition->effect = effect;
    
    return true;
}

WXFTransitionEffect WXFWorkspaceTransitionGetEffect(WXFWorkspaceTransitionRef transition) {
    return transition->effect;
}

bool WXFWorkspaceTransitionSetDuration(WXFWorkspaceTransitionRef transition,
                                       float nanoseconds){
    if (!transition || nanoseconds <= 0)
        return false;
    
    transition->duration_nanoseconds = nanoseconds;
    
    return true;
}

float WXFWorkspaceTransitionGetDuration(WXFWorkspaceTransitionRef transition){
    return transition->duration_nanoseconds;
}

bool WXFWorkspaceTransitionSetEasing(WXFWorkspaceTransitionRef transition,
                                     WXFTransitionEasingMode mode){
    if (!transition || mode > WXFTransitionEasingModeLinear)
        return false;
    
    transition->ease_mode = mode;
    
    return true;
}

WXFTransitionEasingMode WXFWorkspaceTransitionGetEasing(WXFWorkspaceTransitionRef transition){
    return transition->ease_mode;
}

bool WXFWorkspaceTransitionSetDelay(WXFWorkspaceTransitionRef transition,
                                    float nanoseconds){
    if (!transition || nanoseconds <= 0)
        return false;
    
    transition->delay_nanoseconds = nanoseconds;
    
    return true;
}

float WXFWorkspaceTransitionGetDelay(WXFWorkspaceTransitionRef transition){
    return transition->delay_nanoseconds;
}

bool WXFWorkspaceTransitionSetEnabled(WXFWorkspaceTransitionRef transition,
                                      bool enabled){
    bool success = false;
    
    // Do the setting of WS here/call the inner private functions to set values
    
    if (enabled && success)
        transition->enabled = enabled;
    else if (!enabled && success)
        transition->enabled = enabled;
    
    return success;
}

bool WXFWorkspaceTransitionGetEnabled(WXFWorkspaceTransitionRef transition){
    return transition->enabled;
}

bool WXFWorkspaceTransitionSetDirection(WXFWorkspaceTransitionRef transition,
                                        WXFTransitionDirection direction){
    if (!transition || direction > WXFTransitionDirectionRight)
        return false;
    
    transition->direction = direction;
    
    return true;
}

WXFTransitionDirection WXFWorkspaceTransitionGetDirection(WXFWorkspaceTransitionRef transition){
    return transition->direction;
}

bool WXFWorkspaceTransitionSetIntensity(WXFWorkspaceTransitionRef transition,
                                        float intensity){
    if (!transition || intensity < 0)
        return false;
    
    transition->intensity = intensity;
    
    return true;
}

float WXFWorkspaceTransitionGetIntensity(WXFWorkspaceTransitionRef transition){
    return transition->intensity;
}
