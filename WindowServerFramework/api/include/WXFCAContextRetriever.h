//Created by Salty on 10/26/26.

#ifndef WXFCACONTEXTRETRIEVER_H
#define WXFCACONTEXTRETRIEVER_H

#include <WindowServerFramework/WXFBase.h>
#include <CoreGraphics/CGWindow.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFCAContextRetriever;
typedef struct __WXFCAContextRetriever *WXFCAContextRetrieverRef;

typedef uint32_t WXF_CAContextID;

typedef void (*WXFCAContextRetrieverNewContextCallback)(CGWindowID window_id, WXF_CAContextID context_id);

/// Returns the type identifier for WXFCAContextRetriever objects.
WXFTypeID WXFCAContextRetrieverGetTypeID(void);

/// Creates a new CAContext retriever. Returned +1 retained; release with WXFRelease.
WXFCAContextRetrieverRef WXF_RETURNS_RETAINED WXFCAContextRetrieverCreate(void);

/// Creates a CFDicationaryRef with <CGWindowID, WXF_CAContextID> key-value pairs.
/// @param retriever A retriever object.
/// @return Returns a CFDictionaryRef or NULL if the retriever is NULL or not valid.
CFDictionaryRef WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever);

/// Registers a retriever to send callbacks to a given WXFCAContextRetrieverNewContextCallback function.
/// @param retriever A retriever object.
/// @param callback The callback function of type WXFCAContextRetrieverNewContextCallback.
/// @return Returns true for successful registration, false for invalid context/failed registration.
bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback);

#ifdef __cplusplus
}
#endif

#endif /* !WXFCACONTEXTRETRIEVER_H */
