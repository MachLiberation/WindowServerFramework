#ifndef WXFDRAGSHADER_PRIV_H
#define WXFDRAGSHADER_PRIV_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <WindowServerFramework/CGXWindow.h>

/// Number of floats the compositor carries on a window's filter each frame.
#define kWXFFilterParamCount 5
#define kWXFDragShaderDataCount 40   /* == WXF_DRAG_SHADER_DATA_COUNT in the public header */

/// Makes `fragment` (from the precompiled `metallib` bytes) the shader the compositor draws
/// tagged windows with, installing the compositor hooks on first use. Returns false if the
/// framework isn't set up, a required WindowServer symbol is missing on this OS build, or the
/// shader table is full.
bool WXFDragShaderActivate(const void *metallib, size_t length, const char *fragment);

/// Stops substituting. Call after WXFDragShaderDetach.
void WXFDragShaderDeactivate(void);

/// Geometry of the overlay the shader is about to draw on, for the shader's `extra` buffer, in
/// points relative to the overlay's top-left: its size, the margin around the window's frame,
/// and the window's content rectangle (inside that frame). Set before WXFDragShaderAttach.
void WXFDragShaderSetGeometry(float width, float height, float margin,
                              float contentX, float contentY, float contentW, float contentH);

/// Tags `window` so the compositor draws it with the active shader, carrying `params` (5 floats)
/// to the fragment every frame. Fails if the window already has a filter of its own.
bool WXFDragShaderAttach(CGXWindow *window, const float params[kWXFFilterParamCount]);

/// Updates the carried params and marks the window dirty so the compositor re-reads them.
void WXFDragShaderUpdate(CGXWindow *window, const float params[kWXFFilterParamCount],
                         const float data[kWXFDragShaderDataCount]);

/// Removes the tag. `window` may be NULL if the window is already gone.
void WXFDragShaderDetach(CGXWindow *window);

#endif
