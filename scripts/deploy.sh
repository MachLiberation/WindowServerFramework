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
#
# Every tweak links the framework dynamically; it is installed once, next to the tweaks, and
# dyld loads that single copy for all of them. Ammonia loads tweaks when WindowServer starts, so
# new dylibs only take effect after a restart.

set -eu

TWEAKS=/private/var/ammonia/core/tweaks
CONFIG=Debug
RESTART=0
LOGS=0
NAMES=""
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=Release ;;
        --restart) RESTART=1 ;;
        --logs)    LOGS=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) NAMES="$NAMES $arg" ;;
    esac
done
[ -n "$NAMES" ] || NAMES="DragShaderExample"

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
    [ -f "$TWEAKS/lib$NAME.dylib.whitelist" ] || echo WindowServer > "$TWEAKS/lib$NAME.dylib.whitelist"
    file "$TWEAKS/lib$NAME.dylib" | sed 's|^.*/||'
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
