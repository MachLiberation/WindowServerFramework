//Created by Salty on 10/26/26.

#include <WindowServerFramework/WXFCAContextRetriever.h>

#include "WXFBase-Private.h"

WXFCAContextRetrieverRef WXFCAContextRetrieverCreate(void){
    return NULL;
}

void WXFCAContextRetrieverEnumerateContextsWithBlock(WXFCAContextRetrieverRef retriever,
                                                     void(^block)(CGWindowID window_id, WXF_CAContextID context_id, bool *stop)){
    
}

bool WXFCAContextRetrieverRegisterNewContextCallback(WXFCAContextRetrieverRef retriever,
                                                     WXFCAContextRetrieverNewContextCallback callback){
    return true;
}
