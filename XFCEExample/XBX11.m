//
//  XBX11.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// See XBX11.h. Every request is built by hand from the X11 protocol encoding (little-endian, which
// is what Xvfb on this machine uses); replies are only waited for while connecting.

#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "XBX11.h"

#define DEFAULT_DISPLAY "localhost:7"
#define DEFAULT_AUTHORITY "/private/tmp/wxf-x11/Xauthority"

uint32_t XBXAtomWMProtocols, XBXAtomWMDeleteWindow, XBXAtomWMName, XBXAtomNetWMName, XBXAtomUTF8String,
    XBXAtomWMClass, XBXAtomWMNormalHints, XBXAtomString, XBXAtomCardinal, XBXAtomNetWMPid,
    XBXAtomWMTransientFor, XBXAtomWindow, XBXAtomAtom;

static struct {
    int fd;
    uint32_t idBase, idMask, nextId;
    uint32_t maxRequestBytes;
    XBXScreen screen;
    uint8_t outBuffer[1 << 16];
    size_t outLength;
    uint8_t inBuffer[1 << 16];
    size_t inLength;
} X = { .fd = -1 };

static char gError[160];
const char *XBXLastError(void) { return gError; }
static bool Fail(const char *what) {
    snprintf(gError, sizeof gError, "%s (errno %d: %s)", what, errno, strerror(errno));
    return false;
}

static size_t Pad4(size_t n) { return (n + 3) & ~(size_t)3; }

static void Put16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = v >> 8; }
static void Put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint16_t Get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t Get32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static bool WriteAll(const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(X.fd, p, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return false;
        p += w;
        n -= (size_t)w;
    }
    return true;
}

void XBXFlush(void) {
    if (X.fd < 0 || X.outLength == 0) return;
    WriteAll(X.outBuffer, X.outLength);
    X.outLength = 0;
}

// Appends a request; large payloads go straight to the socket after the buffered requests.
static void Send(const uint8_t *head, size_t headLength, const void *payload, size_t payloadLength) {
    if (X.fd < 0) return;
    size_t paddedPayload = Pad4(payloadLength);
    if (X.outLength + headLength + paddedPayload > sizeof X.outBuffer) XBXFlush();
    if (headLength + paddedPayload > sizeof X.outBuffer) {
        XBXFlush();
        WriteAll(head, headLength);
        WriteAll(payload, payloadLength);
        static const uint8_t zeros[4] = {0};
        WriteAll(zeros, paddedPayload - payloadLength);
        return;
    }
    memcpy(X.outBuffer + X.outLength, head, headLength);
    X.outLength += headLength;
    if (payloadLength) {
        memcpy(X.outBuffer + X.outLength, payload, payloadLength);
        memset(X.outBuffer + X.outLength + payloadLength, 0, paddedPayload - payloadLength);
        X.outLength += paddedPayload;
    }
}

static bool ReadExactly(uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t r = recv(X.fd, p, n, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        p += r;
        n -= (size_t)r;
    }
    return true;
}

// MIT-MAGIC-COOKIE-1 for display number `number` from an Xauthority file (big-endian records).
static bool FindCookie(const char *path, const char *number, uint8_t cookie[16]) {
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    const uint8_t *p = data.bytes;
    size_t n = data.length, i = 0;
    while (i + 2 <= n) {
        size_t fields[4];
        const uint8_t *value[4];
        i += 2;   // family
        bool ok = true;
        for (int f = 0; f < 4 && ok; f++) {
            if (i + 2 > n) { ok = false; break; }
            size_t length = (size_t)(p[i] << 8 | p[i + 1]);
            i += 2;
            if (i + length > n) { ok = false; break; }
            fields[f] = length;
            value[f] = p + i;
            i += length;
        }
        if (!ok) return false;
        // fields: address, display number, name, data
        if (fields[1] == strlen(number) && memcmp(value[1], number, fields[1]) == 0 &&
            fields[2] == strlen("MIT-MAGIC-COOKIE-1") && memcmp(value[2], "MIT-MAGIC-COOKIE-1", fields[2]) == 0 &&
            fields[3] == 16) {
            memcpy(cookie, value[3], 16);
            return true;
        }
    }
    return false;
}

static uint32_t InternAtomsReply(void) {
    uint8_t reply[32];
    for (;;) {
        if (!ReadExactly(reply, 32)) return 0;
        if (reply[0] == 1) return Get32(reply + 8);
        // an event or an error that arrived first: not for us
    }
}

static void SendInternAtom(const char *name) {
    size_t n = strlen(name);
    uint8_t head[8] = {16, 0};
    Put16(head + 2, (uint16_t)(2 + Pad4(n) / 4));
    Put16(head + 4, (uint16_t)n);
    Send(head, 8, name, n);
}

bool XBXConnect(void) {
    if (X.fd >= 0) return true;
    // Not $DISPLAY: on the Mac that names XQuartz's own server.
    const char *display = getenv("WXF_X_DISPLAY");
    if (!display || !*display) display = DEFAULT_DISPLAY;
    const char *authority = getenv("WXF_X_AUTHORITY");
    if (!authority || !*authority) authority = DEFAULT_AUTHORITY;

    char host[128] = "localhost";
    const char *colon = strrchr(display, ':');
    if (!colon) return Fail("DISPLAY has no colon");
    if (colon > display && (size_t)(colon - display) < sizeof host) {
        memcpy(host, display, (size_t)(colon - display));
        host[colon - display] = 0;
    }
    int number = atoi(colon + 1);
    char numberText[16];
    snprintf(numberText, sizeof numberText, "%d", number);

    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *found = NULL;
    char port[16];
    snprintf(port, sizeof port, "%d", 6000 + number);
    if (getaddrinfo(host, port, &hints, &found) != 0 || !found) return Fail("cannot resolve the X host");
    int fd = socket(found->ai_family, found->ai_socktype, 0);
    if (fd < 0 || connect(fd, found->ai_addr, found->ai_addrlen) != 0) {
        Fail("cannot connect to the X server");
        if (fd >= 0) close(fd);
        freeaddrinfo(found);
        return false;
    }
    freeaddrinfo(found);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    X.fd = fd;

    uint8_t cookie[16];
    if (!FindCookie(authority, numberText, cookie)) { Fail("no cookie in the Xauthority file"); XBXClose(); return false; }
    // Setup request: little-endian, protocol 11.0, the authorisation name and data.
    uint8_t setup[12 + 20 + 16] = {0};
    setup[0] = 'l';
    Put16(setup + 2, 11);
    Put16(setup + 6, 18);
    Put16(setup + 8, 16);
    memcpy(setup + 12, "MIT-MAGIC-COOKIE-1", 18);   // padded to 20
    memcpy(setup + 32, cookie, 16);
    if (!WriteAll(setup, sizeof setup)) { Fail("cannot send the setup request"); XBXClose(); return false; }

    uint8_t head[8];
    if (!ReadExactly(head, 8) || head[0] != 1) { Fail("the X server refused the connection"); XBXClose(); return false; }
    size_t bodyLength = (size_t)Get16(head + 6) * 4;
    uint8_t *body = malloc(bodyLength);
    if (!body || !ReadExactly(body, bodyLength)) { free(body); XBXClose(); return false; }
    X.idBase = Get32(body + 4);
    X.idMask = Get32(body + 8);
    X.maxRequestBytes = (uint32_t)Get16(body + 18) * 4;
    size_t vendorLength = Get16(body + 16);
    size_t formats = body[21];
    X.screen.minKeycode = body[26];
    const uint8_t *screen = body + 32 + Pad4(vendorLength) + formats * 8;
    X.screen.root = Get32(screen);
    X.screen.width = Get16(screen + 20);
    X.screen.height = Get16(screen + 22);
    X.screen.depth = screen[38];
    free(body);
    X.nextId = 0;

    static const char *names[] = {
        "WM_PROTOCOLS", "WM_DELETE_WINDOW", "WM_NAME", "_NET_WM_NAME", "UTF8_STRING", "WM_CLASS",
        "WM_NORMAL_HINTS", "STRING", "CARDINAL", "_NET_WM_PID", "WM_TRANSIENT_FOR", "WINDOW", "ATOM",
    };
    uint32_t *targets[] = {
        &XBXAtomWMProtocols, &XBXAtomWMDeleteWindow, &XBXAtomWMName, &XBXAtomNetWMName, &XBXAtomUTF8String,
        &XBXAtomWMClass, &XBXAtomWMNormalHints, &XBXAtomString, &XBXAtomCardinal, &XBXAtomNetWMPid,
        &XBXAtomWMTransientFor, &XBXAtomWindow, &XBXAtomAtom,
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) SendInternAtom(names[i]);
    XBXFlush();
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        *targets[i] = InternAtomsReply();
        if (!*targets[i]) { XBXClose(); return false; }
    }
    return true;
}

int XBXFd(void) { return X.fd; }

void XBXClose(void) {
    if (X.fd >= 0) close(X.fd);
    X.fd = -1;
    X.outLength = X.inLength = 0;
}

XBXScreen XBXGetScreen(void) { return X.screen; }

static uint32_t NewId(void) {
    uint32_t id = X.idBase | (++X.nextId & X.idMask);
    return id;
}

uint32_t XBXCreateWindow(int x, int y, int width, int height) {
    uint32_t id = NewId();
    uint8_t r[40] = {0};
    r[0] = 1;                                       // CreateWindow, depth 0 = copy from parent
    Put16(r + 2, 10);                               // 8 + two values
    Put32(r + 4, id);
    Put32(r + 8, X.screen.root);
    Put16(r + 12, (uint16_t)(int16_t)x);
    Put16(r + 14, (uint16_t)(int16_t)y);
    Put16(r + 16, (uint16_t)width);
    Put16(r + 18, (uint16_t)height);
    Put16(r + 22, 1);                               // InputOutput
    Put32(r + 28, 0x2 | 0x800);                     // CWBackPixel | CWEventMask
    Put32(r + 32, 0);                               // black until the first frame arrives
    // KeyPress KeyRelease ButtonPress ButtonRelease EnterWindow LeaveWindow PointerMotion
    // Exposure StructureNotify FocusChange
    Put32(r + 36, 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x8000 | 0x20000 | 0x200000);
    Send(r, sizeof r, NULL, 0);
    return id;
}

static void SimpleWindowRequest(uint8_t opcode, uint32_t window) {
    uint8_t r[8] = {opcode, 0};
    Put16(r + 2, 2);
    Put32(r + 4, window);
    Send(r, 8, NULL, 0);
}

void XBXDestroyWindow(uint32_t window) { SimpleWindowRequest(4, window); }
void XBXMapWindow(uint32_t window) { SimpleWindowRequest(8, window); }

void XBXResizeWindow(uint32_t window, int width, int height) {
    uint8_t r[20] = {12, 0};
    Put16(r + 2, 5);
    Put32(r + 4, window);
    Put16(r + 8, 0x4 | 0x8);                        // width, height
    Put32(r + 12, (uint32_t)width);
    Put32(r + 16, (uint32_t)height);
    Send(r, sizeof r, NULL, 0);
}

static void ChangeProperty(uint32_t window, uint32_t property, uint32_t type, int format,
                           const void *data, size_t units) {
    size_t bytes = units * (size_t)(format / 8);
    uint8_t r[24] = {18, 0};                        // ChangeProperty, Replace
    Put16(r + 2, (uint16_t)(6 + Pad4(bytes) / 4));
    Put32(r + 4, window);
    Put32(r + 8, property);
    Put32(r + 12, type);
    r[16] = (uint8_t)format;
    Put32(r + 20, (uint32_t)units);
    Send(r, sizeof r, data, bytes);
}

void XBXSetTitle(uint32_t window, const char *latin1, const char *utf8) {
    ChangeProperty(window, XBXAtomWMName, XBXAtomString, 8, latin1, strlen(latin1));
    ChangeProperty(window, XBXAtomNetWMName, XBXAtomUTF8String, 8, utf8, strlen(utf8));
}

void XBXSetClass(uint32_t window, const char *instance, const char *cls) {
    char buffer[256];
    size_t a = strlen(instance), b = strlen(cls);
    if (a + b + 2 > sizeof buffer) return;
    memcpy(buffer, instance, a + 1);
    memcpy(buffer + a + 1, cls, b + 1);
    ChangeProperty(window, XBXAtomWMClass, XBXAtomString, 8, buffer, a + b + 2);
}

void XBXSetDeleteProtocol(uint32_t window) {
    uint32_t atom = XBXAtomWMDeleteWindow;
    ChangeProperty(window, XBXAtomWMProtocols, XBXAtomAtom, 32, &atom, 1);
}

void XBXSetTransientFor(uint32_t window, uint32_t parent) {
    ChangeProperty(window, XBXAtomWMTransientFor, XBXAtomWindow, 32, &parent, 1);
}

void XBXSetPid(uint32_t window, uint32_t pid) {
    ChangeProperty(window, XBXAtomNetWMPid, XBXAtomCardinal, 32, &pid, 1);
}

void XBXSetSizeHints(uint32_t window, int minW, int minH, int maxW, int maxH) {
    uint32_t hints[18] = {0};
    if (minW > 0 || minH > 0) { hints[0] |= 16; hints[5] = (uint32_t)minW; hints[6] = (uint32_t)minH; }   // PMinSize
    if (maxW > 0 && maxH > 0) { hints[0] |= 32; hints[7] = (uint32_t)maxW; hints[8] = (uint32_t)maxH; }   // PMaxSize
    uint8_t bytes[72];
    for (int i = 0; i < 18; i++) Put32(bytes + i * 4, hints[i]);
    ChangeProperty(window, XBXAtomWMNormalHints, XBXAtomWMNormalHints, 32, bytes, 18);
}

uint32_t XBXCreateGC(uint32_t window) {
    uint32_t id = NewId();
    uint8_t r[16] = {55, 0};
    Put16(r + 2, 4);
    Put32(r + 4, id);
    Put32(r + 8, window);
    Send(r, sizeof r, NULL, 0);
    return id;
}

void XBXFreeGC(uint32_t gc) {
    uint8_t r[8] = {60, 0};
    Put16(r + 2, 2);
    Put32(r + 4, gc);
    Send(r, 8, NULL, 0);
}

void XBXPutImage(uint32_t window, uint32_t gc, const uint32_t *bgrx, int width, int y, int rows) {
    // Without BIG-REQUESTS a request is at most 65535 words; leave room for the header.
    size_t rowBytes = (size_t)width * 4;
    size_t limit = X.maxRequestBytes ? X.maxRequestBytes : 262140;
    if (limit > 262140) limit = 262140;
    size_t perRequest = (limit - 64) / rowBytes;
    if (perRequest < 1) return;
    for (int done = 0; done < rows;) {
        int n = rows - done < (int)perRequest ? rows - done : (int)perRequest;
        size_t bytes = rowBytes * (size_t)n;
        uint8_t r[24] = {72, 2};                    // PutImage, ZPixmap
        Put16(r + 2, (uint16_t)(6 + bytes / 4));
        Put32(r + 4, window);
        Put32(r + 8, gc);
        Put16(r + 12, (uint16_t)width);
        Put16(r + 14, (uint16_t)n);
        Put16(r + 16, 0);
        Put16(r + 18, (uint16_t)(y + done));
        r[21] = X.screen.depth ? X.screen.depth : 24;
        Send(r, sizeof r, (const uint8_t *)bgrx + (size_t)done * rowBytes, bytes);
        done += n;
    }
}

bool XBXReadEvents(void (^handle)(const XBXEvent *event)) {
    if (X.fd < 0) return false;
    for (;;) {
        ssize_t r = recv(X.fd, X.inBuffer + X.inLength, sizeof X.inBuffer - X.inLength, MSG_DONTWAIT);
        if (r < 0 && errno == EINTR) continue;
        if (r == 0) return false;
        if (r < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return false;
        }
        X.inLength += (size_t)r;
        size_t consumed = 0;
        while (X.inLength - consumed >= 32) {
            const uint8_t *e = X.inBuffer + consumed;
            uint8_t type = e[0] & 0x7f;
            size_t length = 32;
            if (type == 1) length += (size_t)Get32(e + 4) * 4;   // a reply with extra data
            if (X.inLength - consumed < length) break;
            consumed += length;
            XBXEvent ev = { .type = type, .detail = e[1] };
            switch (type) {
                case XBXKeyPress: case XBXKeyRelease: case XBXButtonPress: case XBXButtonRelease:
                case XBXMotionNotify: case XBXEnterNotify: case XBXLeaveNotify:
                    ev.window = Get32(e + 12);
                    ev.x = (int16_t)Get16(e + 24);
                    ev.y = (int16_t)Get16(e + 26);
                    ev.state = Get16(e + 28);
                    break;
                case XBXFocusIn: case XBXFocusOut:
                    ev.window = Get32(e + 4);
                    break;
                case XBXExpose:
                    ev.window = Get32(e + 4);
                    ev.x = (int16_t)Get16(e + 8);
                    ev.y = (int16_t)Get16(e + 10);
                    ev.width = Get16(e + 12);
                    ev.height = Get16(e + 14);
                    break;
                case XBXConfigureNotify:
                    ev.window = Get32(e + 8);
                    ev.x = (int16_t)Get16(e + 16);
                    ev.y = (int16_t)Get16(e + 18);
                    ev.width = Get16(e + 20);
                    ev.height = Get16(e + 22);
                    break;
                case XBXClientMessage:
                    ev.window = Get32(e + 4);
                    ev.atom = Get32(e + 8);
                    ev.data0 = Get32(e + 12);
                    break;
                case 0:
                    NSLog(@"WXF xbridge: X error code %u, request %u", e[1], Get16(e + 8));
                    continue;
                default:
                    continue;
            }
            handle(&ev);
        }
        if (consumed) {
            memmove(X.inBuffer, X.inBuffer + consumed, X.inLength - consumed);
            X.inLength -= consumed;
        }
        if (X.inLength == sizeof X.inBuffer) X.inLength = 0;   // cannot happen with 32-byte events
    }
    return true;
}
