//
//  TBAppMenu.h
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// The app's half of the taskbar's menus. MenuBarAgent only knows an app's menu titles (File, Edit,
// ...); the items under them live in the app. So the tweak is also loaded into the apps whose
// whitelist line names them, and each one shares its whole main menu with the agent:
//
//   app -> agent    the menu as a property list on the app's own SkyLight connection, key
//                   TBAppMenuKey (WXFBus: MIG _XSetConnectionProperty / _XGetConnectionProperty)
//   agent -> app    TBAppMenuInvokeName, a distributed notification carrying the pid and the path
//                   (item indexes from the main menu down) of the item to perform
//
// Each item is a dictionary: t title, e enabled, s state (1 on, -1 mixed), k key equivalent,
// m modifier mask, i index in its menu, sep separator, ind indent level, sub items of its submenu.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TBAppMenuKey;
extern NSString *const TBAppMenuInvokeName;

/// In an ordinary app: starts sharing its main menu and answers invocations. Does nothing in any
/// process that is not a regular app, and may be called early (it waits for the app to run).
void TBAppMenuStart(void);

NS_ASSUME_NONNULL_END
