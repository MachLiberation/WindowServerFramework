//Created by Salty on 10/26/26.
//
// Which CAContext each app window hosts. WindowServer is handed the context id by the client
// (_XCreateWindow, _XSetWindowLayerContext) and passes it to WSWindowBindRemoteCAClientContext,
// which we replace to record it; ~CGXWindow is replaced to forget it. See
// docs/cacontext-internals.md for the evidence.

#include <WindowServerFramework/WXFCAContextRetriever.h>
#include <WindowServerFramework/CGXWindow.h>
#include <errno.h>
#include <os/log.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <os/os_sync_wait_on_address.h>

#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"

//   FREE      - unlocked
//   HELD      - locked, no waiters
//   CONTENDED - locked, at least one thread may be sleeping on the address
#define LOCK_FREE      0
#define LOCK_HELD      1
#define LOCK_CONTENDED 2

// CGXWindow window_type of a window backed by a CAContext (what WSWindowBindRemoteCAClientContext
// checks before it does anything).
#define WINDOW_TYPE_CA 5

struct __WXFCAContextRetriever {
    WXFBase base;
    WXFCAContextRetrieverNewContextCallback callback;
    atomic_int lock;
};

#pragma mark - Wait / wake helpers

static void retriever_wait(atomic_int *addr, int expected_value) {
    if (__builtin_available(macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, *)) {
        (void)os_sync_wait_on_address(addr,
                                      (uint64_t)expected_value,
                                      sizeof(atomic_int),
                                      OS_SYNC_WAIT_ON_ADDRESS_NONE);
    } else {
        sched_yield();
    }
}

static void retriever_wake_one(atomic_int *addr) {
    if (__builtin_available(macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, *)) {
        (void)os_sync_wake_by_address_any(addr,
                                          sizeof(atomic_int),
                                          OS_SYNC_WAKE_BY_ADDRESS_NONE);
    }
}

#pragma mark - Lock

static void lock_acquire(atomic_int *lock) {
    int c = LOCK_FREE;

    if (atomic_compare_exchange_strong_explicit(lock, &c, LOCK_HELD,
                                                memory_order_acquire,
                                                memory_order_relaxed)) {
        return;
    }

    if (c != LOCK_CONTENDED) {
        c = atomic_exchange_explicit(lock, LOCK_CONTENDED, memory_order_acquire);
    }
    while (c != LOCK_FREE) {
        retriever_wait(lock, LOCK_CONTENDED);

        c = atomic_exchange_explicit(lock, LOCK_CONTENDED, memory_order_acquire);
    }
}

static void lock_release(atomic_int *lock) {
    if (atomic_exchange_explicit(lock, LOCK_FREE, memory_order_release) == LOCK_CONTENDED) {
        retriever_wake_one(lock);
    }
}

static void retriever_lock(struct __WXFCAContextRetriever *r)   { lock_acquire(&r->lock); }
static void retriever_unlock(struct __WXFCAContextRetriever *r) { lock_release(&r->lock); }

#pragma mark - Shared state
// One map and one list of retrievers for the whole process: the framework is a single dylib shared
// by every tweak, and the hooks are installed once.
//
// Lock order: gStateLock, then a retriever's lock. Nothing takes them the other way round, and no
// callback runs with either held (a callback may call back into this API).

static atomic_int gStateLock = LOCK_FREE;
static CFMutableDictionaryRef gContexts;                 // CFNumber windowID -> CFNumber contextID
static struct __WXFCAContextRetriever **gRetrievers;     // not retained: a retriever removes itself
static size_t gRetrieverCount, gRetrieverCap;            //   in its destructor, under gStateLock

static CFNumberRef NumberFromUInt32(uint32_t value) {
    int64_t v = value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &v);
}

static void state_lock(void)   { lock_acquire(&gStateLock); }
static void state_unlock(void) { lock_release(&gStateLock); }

static bool registry_add(struct __WXFCAContextRetriever *r) {
    bool ok = true;
    state_lock();
    if (gRetrieverCount == gRetrieverCap) {
        size_t cap = gRetrieverCap ? gRetrieverCap * 2 : 4;
        void *grown = realloc(gRetrievers, cap * sizeof *gRetrievers);
        if (grown) {
            gRetrievers = grown;
            gRetrieverCap = cap;
        } else {
            ok = false;
        }
    }
    if (ok)
        gRetrievers[gRetrieverCount++] = r;
    state_unlock();
    return ok;
}

static void registry_remove(struct __WXFCAContextRetriever *r) {
    state_lock();
    for (size_t i = 0; i < gRetrieverCount; i++) {
        if (gRetrievers[i] == r) {
            gRetrievers[i] = gRetrievers[--gRetrieverCount];
            break;
        }
    }
    state_unlock();
}

/// Copies every registered callback into `*out` (malloc'd, `*count` long; NULL when there are
/// none). Must be called with gStateLock held, which is what keeps the retrievers alive while
/// their callbacks are read.
static void copy_callbacks_locked(WXFCAContextRetrieverNewContextCallback **out, size_t *count) {
    *out = NULL;
    *count = 0;
    if (gRetrieverCount == 0)
        return;
    WXFCAContextRetrieverNewContextCallback *cbs = malloc(gRetrieverCount * sizeof *cbs);
    if (!cbs)
        return;
    size_t n = 0;
    for (size_t i = 0; i < gRetrieverCount; i++) {
        retriever_lock(gRetrievers[i]);
        WXFCAContextRetrieverNewContextCallback cb = gRetrievers[i]->callback;
        retriever_unlock(gRetrievers[i]);
        if (cb)
            cbs[n++] = cb;
    }
    *out = cbs;
    *count = n;
}

#pragma mark - Tracking

/// A window has been given `contextID`. Records it and, if it is new for the window, tells the
/// registered callbacks. A context id of 0 means the window has none (as WindowServer treats it).
static void NoteContext(uint32_t windowID, uint32_t contextID) {
    CFNumberRef key = NumberFromUInt32(windowID);
    CFNumberRef value = contextID ? NumberFromUInt32(contextID) : NULL;
    WXFCAContextRetrieverNewContextCallback *cbs = NULL;
    size_t count = 0;

    state_lock();
    if (!gContexts)
        gContexts = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    if (gContexts && key) {
        CFNumberRef old = CFDictionaryGetValue(gContexts, key);
        if (!value) {
            CFDictionaryRemoveValue(gContexts, key);
        } else if (!old || !CFEqual(old, value)) {
            CFDictionarySetValue(gContexts, key, value);
            copy_callbacks_locked(&cbs, &count);
        }
    }
    state_unlock();

    for (size_t i = 0; i < count; i++)
        cbs[i]((CGWindowID)windowID, (WXF_CAContextID)contextID);

    free(cbs);
    if (key)   CFRelease(key);
    if (value) CFRelease(value);
}

static void ForgetWindow(uint32_t windowID) {
    CFNumberRef key = NumberFromUInt32(windowID);
    if (!key)
        return;
    state_lock();
    if (gContexts)
        CFDictionaryRemoveValue(gContexts, key);
    state_unlock();
    CFRelease(key);
}

#pragma mark - Hooks

// void WSWindowBindRemoteCAClientContext(CGXWindow *window, uint32_t contextID). Runs on
// WindowServer's main thread. The original ignores windows that are not type 5, so we do too. An
// application's window always has a connection (CGXWindow +0x30, what _XCreateWindow passes to
// new_window); a window with none was made by WindowServer or a tweak, and is not reported: a
// tweak that binds an application's context to a window of its own would otherwise show up as a
// second window drawing that application.
void *WXFCAContextOrig_Bind;

typedef void (*BindFn)(CGXWindow *window, uint32_t contextID);

void WXFCAContextHook_Bind(CGXWindow *window, uint32_t contextID) {
    ((BindFn)WXFCAContextOrig_Bind)(window, contextID);
    if (window && window->window_type == WINDOW_TYPE_CA && window->connection)
        NoteContext(window->window_id, contextID);
}

// CGXWindow *CGXWindow::~CGXWindow(CGXWindow *). Called by CGXWindow::release_window, and by
// new_window when it gives up. The id is read first: the window is torn down by the original.
void *WXFCAContextOrig_Destroy;

typedef void *(*DestroyFn)(CGXWindow *window);

void *WXFCAContextHook_Destroy(CGXWindow *window) {
    if (window)
        ForgetWindow(window->window_id);
    return ((DestroyFn)WXFCAContextOrig_Destroy)(window);
}

#pragma mark - Class registration

static void WXFCAContextRetrieverDestructor(WXFTypeRef ref) {
    struct __WXFCAContextRetriever *r = (struct __WXFCAContextRetriever *)ref;

    registry_remove(r);
    retriever_lock(r);
    r->callback = NULL;
    retriever_unlock(r);
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

#pragma mark - Public API

WXFCAContextRetrieverRef WXFCAContextRetrieverCreate(void) {
    // Normally installed by SetupFramework already; this also covers a build where the symbols
    // are missing, which must not hand out a retriever that will never see a window.
    if (!WXFHooksInstall(WXFHookGroupCAContext)) {
        os_log(OS_LOG_DEFAULT, "WXF cacontext: hooks not available");
        return NULL;
    }

    struct __WXFCAContextRetriever *t =
        (struct __WXFCAContextRetriever *)WXFCreateInstance(WXFCAContextRetrieverGetTypeID(),
                                                            sizeof *t);
    if (!t)
        return NULL;

    atomic_init(&t->lock, LOCK_FREE);
    t->callback = NULL;

    if (!registry_add(t)) {
        WXFRelease(t);
        return NULL;
    }
    return t;
}

CFDictionaryRef WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever) {
    if (!retriever || WXFGetTypeID(retriever) != WXFCAContextRetrieverGetTypeID())
        return NULL;

    state_lock();
    CFDictionaryRef copy = gContexts
        ? CFDictionaryCreateCopy(kCFAllocatorDefault, gContexts)
        : CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                             &kCFTypeDictionaryValueCallBacks);
    state_unlock();
    return copy;
}

bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback) {
    if (!retriever || !callback)
        return false;

    retriever_lock(retriever);
    retriever->callback = callback;
    retriever_unlock(retriever);
    return true;
}
