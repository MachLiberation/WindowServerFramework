//
//  TBAgent.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The MenuBarAgent half of the taskbar: the running apps drawn over the bar's app menu strip.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the taskbar inside MenuBarAgent once its application is running. `height` is the bar's
/// height in points, which WindowServer is told to use with WXFMenuBarSetThickness.
void TBAgentStart(double height);

NS_ASSUME_NONNULL_END
