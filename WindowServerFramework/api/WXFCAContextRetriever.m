//Created by Salty on 10/26/26.

#include <WindowServerFramework/WXFCAContextRetriever.h>
#include <pthread.h>

#include "WXFBase-Private.h"

struct __WXFCAContextRetriever {
    WXFBase base;
    WXFCAContextRetrieverNewContextCallback callback;
    atomic_int lock;
};

static const WXFClass kCAContextRetrieverClass = {
    .name = "WXFCAContextRetriever",
    .destructor = NULL,
    .equal = NULL,
};

static WXFTypeID gWXFCAContextRetrieverTypeID = WXFTypeIDInvalid;
static pthread_once_t gCAContextRetrieverOnce = PTHREAD_ONCE_INIT;

static void RegisterCAContextRetrieverClass(void) {
    gWXFCAContextRetrieverTypeID = WXFRegisterClass(&kCAContextRetrieverClass);
}

WXFTypeID WXFWorkspaceTransitionGetTypeID(void) {
    pthread_once(&gCAContextRetrieverOnce, RegisterCAContextRetrieverClass);
    return gWXFCAContextRetrieverTypeID;
}

WXFCAContextRetrieverRef WXFCAContextRetrieverCreate(void) {
    struct __WXFCAContextRetriever *t =
    (struct __WXFCAContextRetriever *)WXFCreateInstance(WXFCAContextRetrieverGetTypeID(),
                                                        sizeof *t);
    if (!t)
        return NULL;
    
    return t;
}

CFDictionaryRef WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever){
    return NULL;
}

bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback){
    return true;
}
