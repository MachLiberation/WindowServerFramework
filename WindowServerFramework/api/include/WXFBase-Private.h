#ifndef WXFBASEPRIV_H
#define WXFBASEPRIV_H

#include "WXFBase.h"
#include <stdatomic.h>
#include <stddef.h>

#define WXF_IMMORTAL_RC UINT32_MAX
#define WXF_MAX_RC      (UINT32_MAX - 1)

typedef struct WXFClass {
    const char *name;
    void (*destructor)(WXFTypeRef obj);            // free owned resources
    int  (*equal)(WXFTypeRef a, WXFTypeRef b);     // optional
} WXFClass;

typedef struct WXFBase {
    const WXFClass *cls;
    atomic_uint_fast32_t retainCount;
    WXFTypeID typeID;
} WXFBase;

WXFTypeID WXFRegisterClass(const WXFClass *cls);

// Allocates sizeof(concrete struct) bytes, zeroed, base initialized, retainCount = 1.
WXFTypeRef WXFCreateInstance(WXFTypeID typeID, size_t size);

/// Makes instance non-releasable. Use only for singleton/shared instances that will never be copied/duplicated, or else memory leaks WILL occur.
void WXFMakeImmortal(WXFTypeRef obj);

#endif
