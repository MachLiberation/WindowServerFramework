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

// What is tracked: the CAContext an application hands WindowServer for each of its windows (at
// window creation, and again whenever it swaps the window's context). This is the context the
// window's content is drawn into, the one a CALayerHost needs to show it. Windows WindowServer
// makes for itself (the menu bar, shields, ...) have local contexts and are not included, nor is
// any window without an owning connection, such as one a tweak creates. Only
// windows bound after SetupFramework ran are known.
//
// A window's entry is dropped when the window is destroyed.

/// Returns the type identifier for WXFCAContextRetriever objects.
WXFTypeID WXFCAContextRetrieverGetTypeID(void);

/// Creates a new CAContext retriever. Returned +1 retained; release with WXFRelease.
/// @return NULL if SetupFramework has not been called, or the WindowServer functions it needs are
///         missing on this OS build.
WXFCAContextRetrieverRef WXF_RETURNS_RETAINED WXFCAContextRetrieverCreate(void);

/// Creates a CFDictionaryRef with <CGWindowID, WXF_CAContextID> key-value pairs: a snapshot of every
/// window that has a context now. Keys and values are CFNumbers (kCFNumberSInt64Type), so read
/// them with CFNumberGetValue. The caller owns the result (release with CFRelease). It is empty if
/// no window has a context.
/// @param retriever A retriever object.
/// @return Returns a CFDictionaryRef or NULL if the retriever is NULL or not valid.
CFDictionaryRef CF_RETURNS_RETAINED WXFCAContextRetrieverObtainContexts(WXFCAContextRetrieverRef retriever);

/// Registers a retriever to send callbacks to a given WXFCAContextRetrieverNewContextCallback function.
/// The callback runs on WindowServer's main thread, once for each window that is given a context
/// and again if it is later given a different one, after the context is visible to
/// WXFCAContextRetrieverObtainContexts. It may call back into this API. A retriever has one
/// callback: registering again replaces it.
/// @param retriever A retriever object.
/// @param callback The callback function of type WXFCAContextRetrieverNewContextCallback.
/// @return Returns true for successful registration, false for invalid context/failed registration.
bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback);

#ifdef __cplusplus
}
#endif

#endif /* !WXFCACONTEXTRETRIEVER_H */
