#include "WXFBase-Private.h"
#include <stdlib.h>
#include <pthread.h>

#define MAX_CLASSES 256
static const WXFClass *gClasses[MAX_CLASSES];
static uint32_t gClassCount = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

WXFTypeID WXFRegisterClass(const WXFClass *cls) {
    pthread_mutex_lock(&gLock);
    WXFTypeID id = WXFTypeIDInvalid;
    if (gClassCount < MAX_CLASSES) {
        id = gClassCount;
        gClasses[gClassCount++] = cls;
    }
    pthread_mutex_unlock(&gLock);
    return id;
}

WXFTypeRef WXFCreateInstance(WXFTypeID typeID, size_t size) {
    if (size < sizeof(WXFBase)) return NULL;

    pthread_mutex_lock(&gLock);
    const WXFClass *cls = (typeID < gClassCount) ? gClasses[typeID] : NULL;
    pthread_mutex_unlock(&gLock);
    if (!cls) return NULL;

    WXFBase *base = calloc(1, size);
    if (!base) return NULL;
    base->cls = cls;
    base->typeID = typeID;
    atomic_init(&base->retainCount, 1);
    return base;
}

WXFTypeRef WXFRetain(WXFTypeRef obj) {
    WXFBase *base = (WXFBase *)obj;
    atomic_fetch_add_explicit(&base->retainCount, 1, memory_order_relaxed);
    return obj;
}

void WXFRelease(WXFTypeRef obj) {
    WXFBase *base = (WXFBase *)obj;
    if (atomic_fetch_sub_explicit(&base->retainCount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        if (base->cls->destructor) base->cls->destructor(obj);
        free(base);
    }
}

WXFTypeID WXFGetTypeID(WXFTypeRef obj) {
    return ((const WXFBase *)obj)->typeID;
}
