//Created by Salty on 10/26/26.

#include <WindowServerFramework/WXFCAContextRetriever.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <os/os_sync_wait_on_address.h>

#include "WXFBase-Private.h"

//   FREE      - unlocked
//   HELD      - locked, no waiters
//   CONTENDED - locked, at least one thread may be sleeping on the address
#define LOCK_FREE      0
#define LOCK_HELD      1
#define LOCK_CONTENDED 2

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

static void retriever_lock(struct __WXFCAContextRetriever *r) {
    int c = LOCK_FREE;

    if (atomic_compare_exchange_strong_explicit(&r->lock, &c, LOCK_HELD,
                                                memory_order_acquire,
                                                memory_order_relaxed)) {
        return;
    }
    
    if (c != LOCK_CONTENDED) {
        c = atomic_exchange_explicit(&r->lock, LOCK_CONTENDED, memory_order_acquire);
    }
    while (c != LOCK_FREE) {
        retriever_wait(&r->lock, LOCK_CONTENDED);

        c = atomic_exchange_explicit(&r->lock, LOCK_CONTENDED, memory_order_acquire);
    }
}

static void retriever_unlock(struct __WXFCAContextRetriever *r) {
    if (atomic_exchange_explicit(&r->lock, LOCK_FREE, memory_order_release) == LOCK_CONTENDED) {
        retriever_wake_one(&r->lock);
    }
}

#pragma mark - Class registration

static void WXFCAContextRetrieverDestructor(WXFTypeRef ref) {
    struct __WXFCAContextRetriever *r = (struct __WXFCAContextRetriever *)ref;

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

#pragma mark - Public API

WXFCAContextRetrieverRef WXFCAContextRetrieverCreate(void) {
    struct __WXFCAContextRetriever *t =
        (struct __WXFCAContextRetriever *)WXFCreateInstance(WXFCAContextRetrieverGetTypeID(),
                                                            sizeof *t);
    if (!t)
        return NULL;

    atomic_init(&t->lock, LOCK_FREE);
    t->callback = NULL;

    return t;
}

CFDictionaryRef WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever) {
    (void)retriever;
    return NULL;
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

//     retriever_lock(r);
//     WXFCAContextRetrieverNewContextCallback cb = r->callback;
//     retriever_unlock(r);
//     if (cb) cb(...);
