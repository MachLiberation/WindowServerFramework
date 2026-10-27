#ifndef WXFBASE_H
#define WXFBASE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_attribute(cf_returns_retained)
#define WXF_RETURNS_RETAINED __attribute__((cf_returns_retained))
#else
#define WXF_RETURNS_RETAINED
#endif

void HookServer(const char *Wanted, void * ReplacementFunc, void **OriginalPtr);

/// Whether SetupFramework has been called with a Gum interceptor (hooks can be installed).
bool WXFIsFrameworkSetUp(void);

/// Resolves a WindowServer-internal symbol by its raw Mach-O name (leading underscore included).
/// Returns NULL if it can't be found.
void *WXFResolveServerSymbol(const char *Wanted);


typedef uint32_t WXFTypeID;
#define WXFTypeIDInvalid ((WXFTypeID)UINT32_MAX)

typedef const void *WXFTypeRef;

///Retains a WXFType object.
WXFTypeRef WXFRetain(WXFTypeRef obj);
///Releases (decrements) a WXFType object's retain count. When the count reaches 0, it is deallocated.
void       WXFRelease(WXFTypeRef obj);
///Gets the WXFTypeID for the object.
WXFTypeID  WXFGetTypeID(WXFTypeRef obj);

#ifdef __cplusplus
}
#endif

#endif
