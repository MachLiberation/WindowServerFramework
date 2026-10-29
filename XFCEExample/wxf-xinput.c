//
//  wxf-xinput.c
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// Reads the input the XFCEExample tweak forwards from WindowServer on stdin and replays it into the
// X server with XTEST. One event per line:
//
//   m X Y            move the pointer to X screen pixel (X, Y)
//   b N 1|0          button N (1 left, 2 middle, 3 right, 4/5/6/7 scroll) down or up
//   k VK 1|0         macOS virtual key code VK down or up
//
// Started by xfce-session.sh with the FIFO as stdin; DISPLAY and XAUTHORITY come from there.

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// kVK_* (HIToolbox/Events.h) to X keysym. 0 = no mapping.
static KeySym KeysymForMacKey(int vk) {
    static const KeySym table[128] = {
        [0]=XK_a, [1]=XK_s, [2]=XK_d, [3]=XK_f, [4]=XK_h, [5]=XK_g, [6]=XK_z, [7]=XK_x, [8]=XK_c, [9]=XK_v,
        [11]=XK_b, [12]=XK_q, [13]=XK_w, [14]=XK_e, [15]=XK_r, [16]=XK_y, [17]=XK_t,
        [18]=XK_1, [19]=XK_2, [20]=XK_3, [21]=XK_4, [22]=XK_6, [23]=XK_5, [24]=XK_equal, [25]=XK_9,
        [26]=XK_7, [27]=XK_minus, [28]=XK_8, [29]=XK_0, [30]=XK_bracketright, [31]=XK_o, [32]=XK_u,
        [33]=XK_bracketleft, [34]=XK_i, [35]=XK_p, [36]=XK_Return, [37]=XK_l, [38]=XK_j,
        [39]=XK_apostrophe, [40]=XK_k, [41]=XK_semicolon, [42]=XK_backslash, [43]=XK_comma,
        [44]=XK_slash, [45]=XK_n, [46]=XK_m, [47]=XK_period, [48]=XK_Tab, [49]=XK_space,
        [50]=XK_grave, [51]=XK_BackSpace, [53]=XK_Escape,
        [55]=XK_Super_L, [56]=XK_Shift_L, [57]=XK_Caps_Lock, [58]=XK_Alt_L, [59]=XK_Control_L,
        [60]=XK_Shift_R, [61]=XK_Alt_R, [62]=XK_Control_R,
        [96]=XK_F5, [97]=XK_F6, [98]=XK_F7, [99]=XK_F3, [100]=XK_F8, [101]=XK_F9, [103]=XK_F11,
        [109]=XK_F10, [111]=XK_F12, [115]=XK_Home, [116]=XK_Page_Up, [117]=XK_Delete, [118]=XK_F4,
        [119]=XK_End, [120]=XK_F2, [121]=XK_Page_Down, [122]=XK_F1,
        [123]=XK_Left, [124]=XK_Right, [125]=XK_Down, [126]=XK_Up,
    };
    return vk >= 0 && vk < 128 ? table[vk] : 0;
}

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "wxf-xinput: cannot open the X display\n"); return 1; }
    int eventBase, errorBase, major, minor;
    if (!XTestQueryExtension(dpy, &eventBase, &errorBase, &major, &minor)) {
        fprintf(stderr, "wxf-xinput: the X server has no XTEST\n");
        return 1;
    }
    setvbuf(stderr, NULL, _IOLBF, 0);
    char line[128];
    while (fgets(line, sizeof line, stdin)) {
        int a, b;
        char kind;
        if (sscanf(line, "%c %d %d", &kind, &a, &b) != 3) continue;
        // Buttons and keys are logged (not motion) so a lost release can be found afterwards.
        if (kind != 'm') {
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            fprintf(stderr, "%ld.%03ld %c %d %d\n", (long)now.tv_sec, now.tv_nsec / 1000000, kind, a, b);
        }
        switch (kind) {
            case 'm': XTestFakeMotionEvent(dpy, 0, a, b, CurrentTime); break;
            case 'b': XTestFakeButtonEvent(dpy, (unsigned)a, b != 0, CurrentTime); break;
            case 'k': {
                KeySym sym = KeysymForMacKey(a);
                KeyCode code = sym ? XKeysymToKeycode(dpy, sym) : 0;
                if (code) XTestFakeKeyEvent(dpy, code, b != 0, CurrentTime);
                break;
            }
        }
        XFlush(dpy);
    }
    XCloseDisplay(dpy);
    return 0;
}
