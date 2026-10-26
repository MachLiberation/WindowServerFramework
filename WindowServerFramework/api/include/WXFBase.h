#ifndef WXFBASE_H
#define WXFBASE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t WXFTypeID;
#define WXFTypeIDInvalid ((WXFTypeID)UINT32_MAX)

typedef const void *WXFTypeRef;

WXFTypeRef WXFRetain(WXFTypeRef obj);
void       WXFRelease(WXFTypeRef obj);
WXFTypeID  WXFGetTypeID(WXFTypeRef obj);

#ifdef __cplusplus
}
#endif

#endif
