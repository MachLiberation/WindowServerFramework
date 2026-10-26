//Created by Salty on 10/26/26.

#include <WindowServerFramework/WXFCAContextRetriever.h>
#include <pthread.h>

#include "WXFBase-Private.h"

struct __WXFCAContextRetriever {
    WXFBase base;
    WXFCAContextRetrieverNewContextCallback callback;
    atomic_int lock;
};

static void retriever_lock(struct __WXFCAContextRetriever *r) {
    int expected = 0;
    while (!atomic_compare_exchange_weak_explicit(&r->lock, &expected, 1,
                                                  memory_order_acquire,
                                                  memory_order_relaxed)) {
        expected = 0;
        sched_yield();
    }
}

static void retriever_unlock(struct __WXFCAContextRetriever *r) {
    atomic_store_explicit(&r->lock, 0, memory_order_release);
}

static void WXFCAContextRetrieverDestructor(WXFTypeRef ref) {
    struct __WXFCAContextRetriever *r = (struct __WXFCAContextRetriever *)ref;

    retriever_lock(r);
    r->callback = NULL;
}

static const WXFClass kCAContextRetrieverClass = {
    .name = "WXFCAContextRetriever",
    .destructor = WXFCAContextRetrieverDestructor,
    .equal = NULL,
};

static WXFTypeID gWXFCAContextRetrieverTypeID = WXFTypeIDInvalid;
static pthread_once_t gCAContextRetrieverOnce = PTHREAD_ONCE_INIT;

static void RegisterCAContextRetrieverClass(void) {
    gWXFCAContextRetrieverTypeID = WXFRegisterClass(&kCAContextRetrieverClass);
}

WXFTypeID WXFCAContextRetrieverGetTypeID(void) {
    pthread_once(&gCAContextRetrieverOnce, RegisterCAContextRetrieverClass);
    return gWXFCAContextRetrieverTypeID;
}

WXFCAContextRetrieverRef WXFCAContextRetrieverCreate(void) {
    struct __WXFCAContextRetriever *t =
    (struct __WXFCAContextRetriever *)WXFCreateInstance(WXFCAContextRetrieverGetTypeID(),
                                                        sizeof *t);
    if (!t)
        return NULL;
    
    atomic_init(&t->lock, 0);
    t->callback = NULL;
    
    return t;
}

CFDictionaryRef WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever){
    return NULL;
}

bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback){
    if (!retriever || !callback)
        return false;
    
    WXFRetain(retriever);
    retriever_lock(retriever);
    retriever->callback = callback;
    retriever_unlock(retriever);
    WXFRelease(retriever);
    return true;
}
