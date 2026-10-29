#!/bin/sh
# XFCEExample's X side. Starts an X server whose screen is a plain file (Xvfb -fbdir), the XFCE
# programs that are installed, and a window manager, all as you (not inside WindowServer).
#
#   XFCEExample/xfce-session.sh start [WIDTHxHEIGHT]    default 1800x1169 (half of a 3600x2338 panel)
#   XFCEExample/xfce-session.sh stop
#   XFCEExample/xfce-session.sh status
#   XFCEExample/xfce-session.sh unstick                 restart twm if the X server stopped answering
#
# The tweak (XFCEExample/Tweak.m) shows that file on a display. Everything lives in /private/tmp/wxf-x11:
#   Xvfb_screen0   the screen, an XWD file the X server keeps up to date
#   input          a FIFO the tweak writes keyboard and mouse events to; wxf-xinput (built from
#                  XFCEExample/wxf-xinput.c on start) replays them into the X server with XTEST
#   Xauthority     the cookie; the X server listens on loopback TCP 6007 because it can't make the
#                  /tmp/.X11-unix socket directory without root
#   bus            the session D-Bus socket XFCE's xfconf needs
#   *.log          each program's output
# XFCE here is whatever MacPorts has: xfce4-panel and thunar. There is no xfwm4, so twm manages windows.
#
# Optional, and kept on this machine rather than in the repo:
#   ~/.config/wxf-xfce/wallpaper.{png,jpg,heic,...}   painted on the root window by wxf-wallpaper
#   ~/.config/picom/picom.conf                        used when picom is installed (PATH or ~/.local/bin);
#                                                      the xrender backend is the one that works on Xvfb. Stock
#                                                      picom needs MIT-SHM fd passing, which XQuartz's Xvfb lacks,
#                                                      so it has to be built with the PutImage patch in docs/display-internals.md.

set -u
DIR=/private/tmp/wxf-x11
XBIN=/opt/X11/bin
PORTS=/opt/local/bin
DISPLAY_NAME=localhost:7
SIZE=${2:-1800x1169}

export XAUTHORITY="$DIR/Xauthority"
export DISPLAY="$DISPLAY_NAME"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$DIR/bus"

# Starts a program fully detached: its own session, no inherited descriptors.
HERE=$(cd "$(dirname "$0")" && pwd)

spawn() {
    NAME=$1; shift
    nohup "$@" </dev/null >"$DIR/$NAME.log" 2>&1 &
}

case "${1:-}" in
start)
    "$0" stop >/dev/null 2>&1
    mkdir -p "$DIR"
    rm -f "$DIR/Xauthority" "$DIR/Xvfb_screen0" "$DIR/bus"
    # Writable by WindowServer's user (the tweak writes the events); the helper opens it read-write so
    # it never sees end-of-file when the tweak closes its end.
    rm -f "$DIR/input"
    mkfifo -m 0622 "$DIR/input"
    clang -O2 -o "$DIR/wxf-xinput" "$HERE/wxf-xinput.c" -I/opt/X11/include -L/opt/X11/lib -lX11 -lXtst \
        || { echo "could not build wxf-xinput (needs the Xcode command line tools and XQuartz)" >&2; exit 1; }
    COOKIE=$(openssl rand -hex 16)
    "$XBIN/xauth" -f "$DIR/Xauthority" add "localhost:7" MIT-MAGIC-COOKIE-1 "$COOKIE" >/dev/null 2>&1
    "$XBIN/xauth" -f "$DIR/Xauthority" add ":7" MIT-MAGIC-COOKIE-1 "$COOKIE" >/dev/null 2>&1
    spawn xvfb "$XBIN/Xvfb" :7 -screen 0 "${SIZE}x24" -fbdir "$DIR" -auth "$DIR/Xauthority" -listen tcp -nolisten local
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$DIR/Xvfb_screen0" ] && "$XBIN/xdpyinfo" >/dev/null 2>&1 && break
        sleep 0.5
    done
    "$XBIN/xdpyinfo" >/dev/null 2>&1 || { echo "X server did not come up; see $DIR/xvfb.log" >&2; exit 1; }
    "$PORTS/dbus-daemon" --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork </dev/null >"$DIR/dbus.log" 2>&1
    # twm asks for each new window to be placed by hand, holding a grab on the whole X server while it
    # waits; RandomPlacement and NoGrabServer turn that off. The Button1 lines matter too: with no
    # binding at all, pressing a window's titlebar froze the whole X server (found headless, 2026-10-28).
    # Button3 on a titlebar asks the window to close (WM_DELETE_WINDOW), which twm has no button for.
    printf 'RandomPlacement\nNoGrabServer\nOpaqueMove\nNoHighlight\nButton1 = : title : f.move\nButton1 = : frame : f.resize\nButton1 = : root : f.nop\nButton3 = : title : f.delete\n' > "$DIR/twmrc"
    spawn twm "$XBIN/twm" -f "$DIR/twmrc"
    sleep 1
    # Wallpaper and compositor go up before any program window, so picom sees every window map (windows
    # that were already mapped when it started came up blank).
    WALL=$(ls "$HOME"/.config/wxf-xfce/wallpaper.* 2>/dev/null | head -n 1)
    if [ -n "$WALL" ] && clang -O2 -fobjc-arc -o "$DIR/wxf-wallpaper" "$HERE/wxf-wallpaper.m" \
            -framework Foundation -framework ImageIO -framework CoreGraphics -I/opt/X11/include -L/opt/X11/lib -lX11 2>"$DIR/wallpaper.log"; then
        "$DIR/wxf-wallpaper" "$WALL" >>"$DIR/wallpaper.log" 2>&1
    fi
    PICOM=$(command -v picom || ls "$HOME/.local/bin/picom" 2>/dev/null)
    if [ -n "$PICOM" ]; then
        CONF="$HOME/.config/picom/picom.conf"
        if [ -f "$CONF" ]; then spawn picom "$PICOM" --config "$CONF"; else spawn picom "$PICOM" --backend xrender; fi
        sleep 1
    fi
    spawn panel "$PORTS/xfce4-panel"
    sleep 3
    spawn thunar "$PORTS/thunar" "$HOME"
    spawn xterm "$XBIN/xterm" -geometry 100x30+760+380
    spawn xinput sh -c "exec '$DIR/wxf-xinput' <> '$DIR/input'"
    echo "X screen $SIZE on $DISPLAY_NAME; files in $DIR"
    ;;
stop)
    for P in wxf-xinput thunar xfce4-panel xterm picom twm; do pkill -x "$P" 2>/dev/null; done
    pkill -f "xfce4/xfconf/xfconfd" 2>/dev/null
    pkill -f "dbus-daemon --session --address=unix:path=$DIR/bus" 2>/dev/null
    pkill -f "Xvfb :7" 2>/dev/null
    rm -f "$DIR/bus"
    echo stopped
    ;;
unstick)
    # If the X server stops answering (a window manager waiting for a button release holds it), killing
    # the window manager frees it; this starts a new one. Windows stay where they are.
    pkill -9 -x twm 2>/dev/null
    sleep 1
    spawn twm "$XBIN/twm" -f "$DIR/twmrc"
    echo "window manager restarted"
    ;;
status)
    for P in Xvfb twm picom xfce4-panel thunar xterm wxf-xinput; do
        pgrep -x "$P" >/dev/null && echo "$P: running" || echo "$P: not running"
    done
    ;;
*)
    echo "usage: $0 start [WIDTHxHEIGHT] | stop | status | unstick" >&2
    exit 2
    ;;
esac
