//Created by Salty on 10/26/26.

#import <Foundation/Foundation.h>

//! Project version number for WindowServerFramework.
FOUNDATION_EXPORT double WindowServerFrameworkVersionNumber;

//! Project version string for WindowServerFramework.
FOUNDATION_EXPORT const unsigned char WindowServerFrameworkVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <WindowServerFramework/PublicHeader.h>
#import <WindowServerFramework/WXFWorkspaceTransition.h> 
#import <WindowServerFramework/WXFBase.h>
#import <WindowServerFramework/WXFCAContextRetriever.h>

// Call this before any work in your ammonia tweaks
// `LoadFunction`, passing the `void *gum_interceptor`
void SetupFramework(void * ammonia_gum_interceptor);
