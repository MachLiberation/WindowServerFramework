#!/bin/sh
# Builds tweaks (universal arm64 + arm64e), signs them, and installs them and the shared
# WindowServerFramework into Ammonia's tweaks folder.
#
#   scripts/deploy.sh                       build + install DragShaderExample
#   scripts/deploy.sh Foo Bar               build + install the named tweak targets
#   scripts/deploy.sh --release             build the Release configuration
#   scripts/deploy.sh --restart             also restart WindowServer so the new dylibs load
#                                           (this LOGS YOU OUT: save your work first)
#   scripts/deploy.sh --logs                afterwards, stream the WXF log lines (ctrl-c to stop)
#   scripts/deploy.sh --hide-dock           keep the Dock out of the way (autohide, no reveal delay)
#   scripts/deploy.sh --show-dock           put the Dock's settings back
#
# A tweak that also works inside MenuBarAgent (TaskbarExample) is loaded there when the agent
# restarts: `killall MenuBarAgent` is enough, no logout. The WindowServer half needs the restart.
#
# Every tweak links the framework dynamically; it is installed once, next to the tweaks, and
# dyld loads that single copy for all of them. Ammonia loads tweaks when WindowServer starts, so
# new dylibs only take effect after a restart.

set -eu

TWEAKS=/private/var/ammonia/core/tweaks
CONFIG=Debug
RESTART=0
LOGS=0
DOCK=""
NAMES=""
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=Release ;;
        --restart) RESTART=1 ;;
        --logs)    LOGS=1 ;;
        --hide-dock) DOCK=hide ;;
        --show-dock) DOCK=show ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) NAMES="$NAMES $arg" ;;
    esac
done
if [ -z "$NAMES" ] && [ -z "$DOCK" ]; then NAMES="DragShaderExample"; fi

if [ "$DOCK" = hide ]; then
    # A delay this long is how the Dock is kept from ever sliding in on a screen edge.
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock autohide-delay -float 1000
    killall Dock
    echo "Dock hidden (scripts/deploy.sh --show-dock puts it back)"
elif [ "$DOCK" = show ]; then
    defaults delete com.apple.dock autohide-delay 2>/dev/null || true
    defaults write com.apple.dock autohide -bool false
    killall Dock
    echo "Dock shown"
fi
[ -n "$NAMES" ] || exit 0

# The processes a tweak is loaded into (Ammonia's whitelist), one per line. Most only work inside
# WindowServer. TaskbarExample also goes into the apps whose whole menu it shows (TBAppMenu); an
# app that is already running has to be relaunched to get it.
whitelist_for() {
    case "$1" in
        # The apps XFCEExample/xfce-open.sh can put on the X session (it only acts in an app started
        # that way). Sandboxed apps (TextEdit, Calculator, Notes, ...) are not listed: the sandbox
        # blocks their connection to the X server.
        XFCEExample) printf '%s\n' WindowServer Terminal "Activity Monitor" Console "Disk Utility" \
            "Font Book" Automator "Script Editor" "Keychain Access" Finder ;;
        TaskbarExample) printf '%s\n' WindowServer MenuBarAgent Finder TextEdit Safari Terminal iTerm2 \
            "Brave Browser" "Activity Monitor" "GitHub Desktop" Claude Xcode ;;
        *) echo "WindowServer" ;;
    esac
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="${TMPDIR:-/tmp}/wxf-build"
PRODUCTS="$BUILD/Build/Products/$CONFIG"
FRAMEWORK="$PRODUCTS/WindowServerFramework.framework"

for NAME in $NAMES; do
    echo "==> building $NAME ($CONFIG, arm64 + arm64e)"
    xcodebuild -project "$ROOT/WindowServerFramework.xcodeproj" -scheme "$NAME" \
        -configuration "$CONFIG" -derivedDataPath "$BUILD" \
        ARCHS="arm64 arm64e" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO -quiet build
    [ -f "$PRODUCTS/lib$NAME.dylib" ] || { echo "build produced no lib$NAME.dylib" >&2; exit 1; }
done
[ -d "$FRAMEWORK" ] || { echo "build produced no framework at $FRAMEWORK" >&2; exit 1; }

echo "==> signing"
codesign -f -s - "$FRAMEWORK"
for NAME in $NAMES; do codesign -f -s - "$PRODUCTS/lib$NAME.dylib"; done

# The framework first, so a tweak never loads without it. A new directory and inode each time:
# WindowServer may still have the old copy mapped.
echo "==> installing to $TWEAKS"
rm -rf "$TWEAKS/WindowServerFramework.framework.new"
cp -R "$FRAMEWORK" "$TWEAKS/WindowServerFramework.framework.new"
rm -rf "$TWEAKS/WindowServerFramework.framework"
mv "$TWEAKS/WindowServerFramework.framework.new" "$TWEAKS/WindowServerFramework.framework"

for NAME in $NAMES; do
    cp "$PRODUCTS/lib$NAME.dylib" "$TWEAKS/.lib$NAME.dylib.new"
    mv -f "$TWEAKS/.lib$NAME.dylib.new" "$TWEAKS/lib$NAME.dylib"
    # Add the processes this tweak needs; leave whatever else the file already names.
    touch "$TWEAKS/lib$NAME.dylib.whitelist"
    whitelist_for "$NAME" | while IFS= read -r PROC; do
        grep -qxF "$PROC" "$TWEAKS/lib$NAME.dylib.whitelist" || echo "$PROC" >> "$TWEAKS/lib$NAME.dylib.whitelist"
    done
    file "$TWEAKS/lib$NAME.dylib" | sed 's|^.*/||'
done

# XFCEExample's app half is a second dylib, the XFCEBridge target (the XFCEExample scheme builds it
# first): it links AppKit, which WindowServer must not load, so it sits in a folder of its own.
for NAME in $NAMES; do
    [ "$NAME" = XFCEExample ] || continue
    [ -f "$PRODUCTS/libXFCEBridge.dylib" ] || { echo "build produced no libXFCEBridge.dylib" >&2; exit 1; }
    mkdir -p "$TWEAKS/XFCEExample.support"
    codesign -f -s - "$PRODUCTS/libXFCEBridge.dylib"
    cp "$PRODUCTS/libXFCEBridge.dylib" "$TWEAKS/XFCEExample.support/.libXFCEBridge.dylib.new"
    mv -f "$TWEAKS/XFCEExample.support/.libXFCEBridge.dylib.new" "$TWEAKS/XFCEExample.support/libXFCEBridge.dylib"
    echo "installed $TWEAKS/XFCEExample.support/libXFCEBridge.dylib"
done

if [ "$RESTART" = 1 ]; then
    echo "==> restarting WindowServer (logging you out)"
    sudo killall WindowServer
    exit 0
fi

echo "done. Restart WindowServer to load it (scripts/deploy.sh --restart)."

if [ "$LOGS" = 1 ]; then
    exec log stream --predicate 'eventMessage CONTAINS "WXF"'
fi
