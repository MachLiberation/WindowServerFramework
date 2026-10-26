//Created by Salty on 10/26/26.

#ifndef WXFCACONTEXTRETRIEVER_H
#define WXFCACONTEXTRETRIEVER_H

#include <WindowServerFramework/WXFBase.h>
#include <CoreGraphics/CGWindow.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFCAContextRetriever;
typedef struct __WXFCAContextRetriever *WXFCAContextRetrieverRef;

typedef uint32_t WXF_CAContextID;

typedef void (*WXFCAContextRetrieverNewContextCallback)(CGWindowID window_id, WXF_CAContextID context_id);

WXFCAContextRetrieverRef WXF_RETURNS_RETAINED WXFCAContextRetrieverCreate(void);

void WXFCAContextRetrieverEnumerateContextsWithBlock(WXFCAContextRetrieverRef retriever,
                                                     void(^block)(CGWindowID window_id, WXF_CAContextID context_id, bool *stop));

bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback);

#ifdef __cplusplus
}
#endif

#endif
