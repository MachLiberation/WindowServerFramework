//
//  WXFBus.h
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// A way for two GUI processes to hand each other a property list through WindowServer, with no
// service to register and nothing to hook. Every process has a SkyLight connection, and WindowServer
// keeps a dictionary of properties for it (MIG _XSetConnectionProperty, stored by
// CGXSetConnectionUntrustedProperty; read back by _XGetConnectionProperty). A process may only set
// properties on its own connection, but may read them from any connection. So:
//
//   publisher    WXFBusPublish("key", plist)        on its own connection
//   reader       WXFBusCopy(WXFBusConnectionForPID(pid), "key")
//
// The value travels as serialized property list bytes in an out-of-line MIG descriptor, so it can be
// big (a whole menu bar). The key is at most 127 bytes. The one name WindowServer refuses is
// "menuBarAppBarInfos", which is its own. How it is known: docs/taskbar-internals.md.

#ifndef WXFBUS_H
#define WXFBUS_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sets `key` on this process's own connection to `value` (a property list: dictionaries, arrays,
/// strings, numbers, booleans, data, dates), or removes it when `value` is NULL.
/// @return false if the request could not be sent.
bool WXFBusPublish(const char *key, CFPropertyListRef value);

/// The value of `key` on `connection`, or NULL when there is none. The caller releases it.
CFPropertyListRef WXFBusCopy(uint32_t connection, const char *key);

/// The SkyLight connection id of the process `pid`, found through one of its windows; 0 when it has
/// none (an app with no window yet). This process's own is WXFBusMainConnection().
uint32_t WXFBusConnectionForPID(pid_t pid);

/// This process's own connection id.
uint32_t WXFBusMainConnection(void);

#ifdef __cplusplus
}
#endif

#endif
