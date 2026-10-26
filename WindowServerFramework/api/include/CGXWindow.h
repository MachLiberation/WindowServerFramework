//
//  CGXWindow.h
//  WindowServerFramework
//
//  Created by bedtime on 10/26/26.
//

#ifndef CGXWINDOW_H
#define CGXWINDOW_H

#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CGXConnection CGXConnection;
typedef struct WFXWindowFilter WFXWindowFilter;

/// Raw storage for WindowServer's private 3D transform type. Only the size
/// matters here; the layout is embedded in CGXWindow and must not change.
typedef struct WFXTransform3D {
    uint8_t _storage[0x80];
} WFXTransform3D;

/// A WindowServer window as laid out in the WindowServer process.
/// Field offsets are annotated and must be preserved.
typedef struct CGXWindow {
    uint32_t       window_id;                           // 0x000
    uint32_t       window_type;                         // 0x004
    uint8_t        _pad_008[0x8];
    void          *ca_backing;                          // 0x010
    uint8_t        _pad_018[0x8];
    int32_t        level;                               // 0x020
    uint8_t        _pad_024[0xc];
    CGXConnection *connection;                          // 0x030
    uint8_t        _pad_038[0x18];
    uint32_t       connection_id;                       // 0x050  cid for CGXGetConnectionAppName
    uint8_t        _pad_054[0x70];
    uint32_t       screen_geometry_seed;                // 0x0c4
    uint8_t        _pad_0c8[0x20];
    void          *clip_shape;                          // 0x0e8
    uint8_t        _pad_0f0[0x30];
    void          *global_clip_shape;                   // 0x120
    void          *layer_clip_shape;                    // 0x128
    uint8_t        _pad_130[0x50];
    void          *shape;                               // 0x180
    uint8_t        _pad_188[0x30];
    void          *shape_data;                          // 0x1b8
    uint8_t        _pad_1c0[0x28];
    float          alpha;                               // 0x1e8
    float          system_alpha;                        // 0x1ec
    uint8_t        _pad_1f0[0x30];
    float          backing_store_resolution;            // 0x220
    uint8_t        _pad_224[0x4];
    float          backing_store_override_resolution;   // 0x228
    uint8_t        _pad_22c[0x4];
    CGSize         backing_store_pixel_dimensions_hint; // 0x230
    uint8_t        _pad_240[0x10];
    void          *backing_store;                       // 0x250
    void          *workspace_data;                      // 0x258
    uint8_t        _pad_260[0x230];
    void          *window_mask;                         // 0x490
    void          *frozen_backing;                      // 0x498
    uint8_t        _pad_4a0[0x8];
    WFXTransform3D  transform;                           // 0x4a8
    WFXTransform3D  system_transform;                    // 0x528
    WFXTransform3D  deformation_transform;               // 0x5a8
    uint8_t        _pad_628[0x180];
    void          *transform_stack;                     // 0x7a8
    uint8_t        _pad_7b0[0xc];
    uint32_t       event_mask;                          // 0x7bc
    uint8_t        _pad_7c0[0x10];
    double         sfx_corner_radius;                   // 0x7d0
    uint8_t        _pad_7d8[0x10];
    uint64_t       dominant_display_id;                 // 0x7e8
    uint8_t        _pad_7f0[0x6c];
    float          brightness;                          // 0x85c
    uint8_t        _pad_860[0x8];
    double         corner_radius;                       // 0x868
    double         debug_corner_radius;                 // 0x870
    double         corner_radii[4];                     // 0x878
    uint8_t        _pad_898[0x8];
    void          *mask_path;                           // 0x8a0
    WFXWindowFilter *filter;                             // 0x8a8
    void          *mesh;                                // 0x8b0
    void          *frame_mesh_cache;                    // 0x8b8
    void          *fade_state;                          // 0x8c0
    uint8_t        _pad_8c8[0x18];
    int32_t        screen_state;                        // 0x8e0
    uint8_t        _pad_8e4[0x7c];
    uint64_t       flags;                               // 0x960
} CGXWindow;


#define _ASSERT_OFFSET(field, off) \
    _Static_assert(offsetof(CGXWindow, field) == (off), \
                   "CGXWindow." #field " is not at " #off)

_ASSERT_OFFSET(window_id,           0x000);
_ASSERT_OFFSET(window_type,         0x004);
_ASSERT_OFFSET(ca_backing,          0x010);
_ASSERT_OFFSET(level,               0x020);
_ASSERT_OFFSET(connection,          0x030);
_ASSERT_OFFSET(connection_id,       0x050);
_ASSERT_OFFSET(screen_geometry_seed, 0x0c4);
_ASSERT_OFFSET(clip_shape,          0x0e8);
_ASSERT_OFFSET(global_clip_shape,   0x120);
_ASSERT_OFFSET(layer_clip_shape,    0x128);
_ASSERT_OFFSET(shape,               0x180);
_ASSERT_OFFSET(shape_data,          0x1b8);
_ASSERT_OFFSET(alpha,               0x1e8);
_ASSERT_OFFSET(system_alpha,        0x1ec);
_ASSERT_OFFSET(backing_store_resolution, 0x220);
_ASSERT_OFFSET(backing_store_pixel_dimensions_hint, 0x230);
_ASSERT_OFFSET(backing_store,       0x250);
_ASSERT_OFFSET(workspace_data,      0x258);
_ASSERT_OFFSET(window_mask,         0x490);
_ASSERT_OFFSET(frozen_backing,      0x498);
_ASSERT_OFFSET(transform,           0x4a8);
_ASSERT_OFFSET(system_transform,    0x528);
_ASSERT_OFFSET(deformation_transform, 0x5a8);
_ASSERT_OFFSET(transform_stack,     0x7a8);
_ASSERT_OFFSET(event_mask,          0x7bc);
_ASSERT_OFFSET(sfx_corner_radius,   0x7d0);
_ASSERT_OFFSET(dominant_display_id, 0x7e8);
_ASSERT_OFFSET(corner_radius,       0x868);
_ASSERT_OFFSET(debug_corner_radius, 0x870);
_ASSERT_OFFSET(corner_radii,        0x878);
_ASSERT_OFFSET(brightness,          0x85c);
_ASSERT_OFFSET(mask_path,           0x8a0);
_ASSERT_OFFSET(filter,              0x8a8);
_ASSERT_OFFSET(mesh,                0x8b0);
_ASSERT_OFFSET(frame_mesh_cache,    0x8b8);
_ASSERT_OFFSET(fade_state,          0x8c0);
_ASSERT_OFFSET(screen_state,        0x8e0);
_ASSERT_OFFSET(flags,               0x960);

#ifdef __cplusplus
}
#endif

#endif /* CGXWINDOW_H */
