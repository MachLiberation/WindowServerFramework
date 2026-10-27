//Created by Salty on 10/26/26.

#import <Foundation/Foundation.h>

//! Project version number for WindowServerFramework.
FOUNDATION_EXPORT double WindowServerFrameworkVersionNumber;

//! Project version string for WindowServerFramework.
FOUNDATION_EXPORT const unsigned char WindowServerFrameworkVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <WindowServerFramework/PublicHeader.h>
#import <WindowServerFramework/WXFDragAnimation.h>
#import <WindowServerFramework/WXFDrag.h>
#import <WindowServerFramework/WXFBase.h>

// The framework is a single dylib shared by every tweak that uses it (dyld loads it once, from
// /private/var/ammonia/core/tweaks), so tweaks cooperate instead of each hooking WindowServer on its
// own. Where two tweaks want the same thing, say two drag shaders, the later one wins.
//
// Call this before any work in your ammonia tweaks
// `LoadFunction`, passing the `void *gum_interceptor`
void SetupFramework(void * ammonia_gum_interceptor);
