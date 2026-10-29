#!/bin/sh
# Starts a Mac app so its windows appear on XFCEExample's X session (XBridge.m). The app's own
# windows are hidden on the Mac; the X session shows them and sends its keyboard and mouse back.
#
#   XFCEExample/xfce-open.sh "Terminal"              by name, a path to the .app, or a bundle id
#   XFCEExample/xfce-open.sh Finder                  relaunches Finder with the bridge (it is always
#                                                    running, so there is no second instance to start);
#                                                    its windows leave the Mac until it is relaunched
#   XFCEExample/xfce-open.sh --restore Finder        relaunches Finder normally
#   XFCEExample/xfce-open.sh --inject "Some App"     insert the bridge with DYLD_INSERT_LIBRARIES
#                                                    instead of relying on the tweak (for an app
#                                                    scripts/deploy.sh does not whitelist)
#
# Needs xfce-session.sh start first. A sandboxed app (TextEdit, Calculator, Notes, Preview, ...) can't
# reach the X server and just runs on the Mac. Quit an app that is already running first: this starts a
# new instance with -n, and apps with one window per document may reopen their old windows.
#
# Credit: bedtime.
set -eu
TWEAKS=/private/var/ammonia/core/tweaks
INJECT=0
RESTORE=0
if [ "${1:-}" = "--inject" ]; then INJECT=1; shift; fi
if [ "${1:-}" = "--restore" ]; then RESTORE=1; shift; fi
[ $# -ge 1 ] || { echo "usage: $0 [--inject] <app name | path.app | bundle id>" >&2; exit 2; }
APP=$1
if [ "$APP" = Finder ]; then
    if [ "$RESTORE" = 1 ]; then
        killall Finder
        echo "Finder relaunched normally"
        exit 0
    fi
    # launchd restarts Finder with whatever is in its environment, so set the flag for the restart
    # only; the running Finder keeps it.
    [ -s /private/tmp/wxf-x11/Xauthority ] || { echo "no X session: run XFCEExample/xfce-session.sh start first" >&2; exit 1; }
    launchctl setenv WXF_XBRIDGE 1
    killall Finder
    sleep 3
    launchctl unsetenv WXF_XBRIDGE
    osascript -e 'tell application "Finder" to make new Finder window' >/dev/null 2>&1 || true
    echo "Finder relaunched with the bridge; xfce-open.sh --restore Finder undoes it"
    exit 0
fi
[ -s /private/tmp/wxf-x11/Xauthority ] || { echo "no X session: run XFCEExample/xfce-session.sh start first" >&2; exit 1; }

if [ "$INJECT" = 1 ]; then
    DYLIB="$TWEAKS/XFCEExample.support/libXFCEBridge.dylib"
    [ -f "$DYLIB" ] || { echo "no $DYLIB: run scripts/deploy.sh XFCEExample" >&2; exit 1; }
    case "$APP" in
        *.app) PATH_APP=$APP ;;
        *) PATH_APP=$(ls -d "/Applications/$APP.app" "/System/Applications/$APP.app" "/System/Applications/Utilities/$APP.app" 2>/dev/null | head -n 1) ;;
    esac
    [ -d "$PATH_APP" ] || { echo "cannot find $APP" >&2; exit 1; }
    EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PATH_APP/Contents/Info.plist")
    WXF_XBRIDGE=1 DYLD_INSERT_LIBRARIES="$DYLIB" nohup "$PATH_APP/Contents/MacOS/$EXE" </dev/null >/dev/null 2>&1 &
    echo "started $EXE (pid $!) with the bridge inserted"
else
    case "$APP" in
        *.app) open -n --env WXF_XBRIDGE=1 "$APP" ;;
        *.*.*) open -n --env WXF_XBRIDGE=1 -b "$APP" ;;
        *) open -n --env WXF_XBRIDGE=1 -a "$APP" ;;
    esac
    echo "started $APP; see /usr/bin/log show --last 2m --process '<app name>' | grep xbridge"
fi
