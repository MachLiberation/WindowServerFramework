#ifndef WXFBASE_H
#define WXFBASE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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
