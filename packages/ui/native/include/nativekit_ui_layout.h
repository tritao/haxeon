#ifndef NATIVEKIT_UI_LAYOUT_H
#define NATIVEKIT_UI_LAYOUT_H

#include "nativekit_ui.h"

#include <stdint.h>

/*
 * This is the NativeKit/Haxe frontend bridge. It is deliberately separate
 * from nativekit_ui.h: this batched, versioned bridge carries render/layout
 * data only. Haxe owns widgets, identity, input, accessibility, and state.
 */

#ifdef __cplusplus
extern "C" {
#endif

/** Layout bridge and wire-format versions and fixed sizes. */
enum {
    NKUI_LAYOUT_API_VERSION = 28,
    NKUI_LAYOUT_TRANSACTION_VERSION = 22,
    NKUI_LAYOUT_PATCH_VERSION = 23,
    NKUI_LAYOUT_PATCH_HEADER_BYTES = 32,
    NKUI_LAYOUT_TRANSACTION_HEADER_BYTES = 16,
    NKUI_LAYOUT_NODE_RECORD_BYTES = 196,
    NKUI_LAYOUT_MAX_TRANSACTION_BYTES = 16 * 1024 * 1024,
    NKUI_LAYOUT_RESOLVED_ITEM_BYTES = 96
};

/** Bit flags stored in each node's clip-flags field. */
typedef uint32_t nkui_layout_clip_flags;
enum NK_FLAGS(nkui_layout_clip_flags) {
    NKUI_LAYOUT_CLIP_HORIZONTAL = 1u << 0,
    NKUI_LAYOUT_CLIP_VERTICAL = 1u << 1
};

/** Node flags stored at NKUI_LAYOUT_NODE_FLAGS_OFFSET. */
typedef uint32_t nkui_layout_node_flags;
enum NK_FLAGS(nkui_layout_node_flags) {
    NKUI_LAYOUT_NODE_VISIBLE = 1u << 0,
    NKUI_LAYOUT_NODE_FLOATING = 1u << 1,
    NKUI_LAYOUT_NODE_CLIP_TO_PARENT = 1u << 2,
    /** Floating overlay above ordinary content, scoped to the nearest enclosing overlay. */
    NKUI_LAYOUT_NODE_OVERLAY = 1u << 3,
    /** Layout hid the node, as a placer hides a scrollbar with nothing to scroll: not drawn. */
    NKUI_LAYOUT_NODE_HIDDEN = 1u << 4
};

/** Persistent rendering policy for a retained custom-paint plane. */
typedef uint32_t nkui_layout_cache_policy;
enum NK_ENUM(nkui_layout_cache_policy) {
    NKUI_LAYOUT_CACHE_NONE = 0,
    NKUI_LAYOUT_CACHE_AUTO = 1,
    NKUI_LAYOUT_CACHE_RASTER = 2
};

/** Flags returned with each resolved item. */
typedef uint32_t nkui_layout_resolved_flags;
enum NK_FLAGS(nkui_layout_resolved_flags) {
    NKUI_LAYOUT_RESOLVED_VISIBLE = 1u << 0,
    NKUI_LAYOUT_RESOLVED_HAS_BASELINE = 1u << 1
};

/** Visual content kinds encoded in the transaction. */
typedef uint32_t nkui_layout_visual_kind;
enum NK_ENUM(nkui_layout_visual_kind) {
    NKUI_LAYOUT_VISUAL_BOX = 1,
    NKUI_LAYOUT_VISUAL_TEXT = 2,
    NKUI_LAYOUT_VISUAL_IMAGE = 3,
    NKUI_LAYOUT_VISUAL_CUSTOM = 4
};

/**
 * Field offsets of one node record: a node as the framework laid it out and paints it (ADR 0009). Its bounds are in layout
 * coordinates, before its transform; its text goes at the text offsets from its bounds, wrapped at the text width; its
 * baseline is in layout coordinates, NaN when it has none; a scroll container's content moves left and up by its scroll
 * offsets, ahead of its own transform.
 */
enum {
    NKUI_LAYOUT_NODE_ID_OFFSET = 0,
    NKUI_LAYOUT_NODE_PARENT_OFFSET = 4,
    NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET = 8,
    NKUI_LAYOUT_NODE_FLAGS_OFFSET = 12,
    NKUI_LAYOUT_NODE_CLIP_FLAGS_OFFSET = 16,
    NKUI_LAYOUT_NODE_X_OFFSET = 20,
    NKUI_LAYOUT_NODE_Y_OFFSET = 24,
    NKUI_LAYOUT_NODE_WIDTH_OFFSET = 28,
    NKUI_LAYOUT_NODE_HEIGHT_OFFSET = 32,
    NKUI_LAYOUT_NODE_TEXT_X_OFFSET = 36,
    NKUI_LAYOUT_NODE_TEXT_Y_OFFSET = 40,
    NKUI_LAYOUT_NODE_TEXT_WIDTH_OFFSET = 44,
    NKUI_LAYOUT_NODE_BASELINE_OFFSET = 48,
    NKUI_LAYOUT_NODE_SCROLL_X_OFFSET = 52,
    NKUI_LAYOUT_NODE_SCROLL_Y_OFFSET = 56,
    NKUI_LAYOUT_NODE_BACKGROUND_OFFSET = 60,
    NKUI_LAYOUT_NODE_RADIUS_TOP_LEFT_OFFSET = 76,
    NKUI_LAYOUT_NODE_RADIUS_TOP_RIGHT_OFFSET = 80,
    NKUI_LAYOUT_NODE_RADIUS_BOTTOM_LEFT_OFFSET = 84,
    NKUI_LAYOUT_NODE_RADIUS_BOTTOM_RIGHT_OFFSET = 88,
    NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET = 92,
    NKUI_LAYOUT_NODE_TEXT_LENGTH_OFFSET = 96,
    NKUI_LAYOUT_NODE_TEXT_COLOR_OFFSET = 100,
    NKUI_LAYOUT_NODE_FONT_FAMILY_OFFSET = 116,
    NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET = 120,
    NKUI_LAYOUT_NODE_LETTER_SPACING_OFFSET = 124,
    NKUI_LAYOUT_NODE_LINE_HEIGHT_OFFSET = 128,
    NKUI_LAYOUT_NODE_TEXT_WRAP_OFFSET = 132,
    NKUI_LAYOUT_NODE_TEXT_ALIGNMENT_OFFSET = 136,
    NKUI_LAYOUT_NODE_TEXT_DIRECTION_OFFSET = 140,
    NKUI_LAYOUT_NODE_TAB_WIDTH_OFFSET = 144,
    NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET = 148,
    NKUI_LAYOUT_NODE_TRANSFORM_B_OFFSET = 152,
    NKUI_LAYOUT_NODE_TRANSFORM_C_OFFSET = 156,
    NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET = 160,
    NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET = 164,
    NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET = 168,
    /** The transform's origin as fractions of the node's bounds; the default is its center. */
    NKUI_LAYOUT_NODE_TRANSFORM_ORIGIN_X_OFFSET = 172,
    NKUI_LAYOUT_NODE_TRANSFORM_ORIGIN_Y_OFFSET = 176,
    /** Paint order of a floating node among its siblings' layers. */
    NKUI_LAYOUT_NODE_Z_INDEX_OFFSET = 180,
    /** Paint/text revision consumed by retained render caches. */
    NKUI_LAYOUT_NODE_CONTENT_REVISION_OFFSET = 184,
    /** Bounds/transform/clip revision. */
    NKUI_LAYOUT_NODE_GEOMETRY_REVISION_OFFSET = 188,
    /** Opacity/effects revision. */
    NKUI_LAYOUT_NODE_COMPOSITE_REVISION_OFFSET = 192
};

/** Opaque retained layout session used by a Haxe-owned component tree. */
NK_DECLARE_HANDLE(nkui_layout_session);

/** Resolved geometry for one node in the most recently submitted layout. */
typedef struct nkui_layout_item {
    /** Set to sizeof(nkui_layout_item) or a larger compatible size. */
    uint32_t struct_size NK_STRUCT_SIZE;
    uint32_t node_id;
    nkui_layout_resolved_flags flags;
    /** Layout bounds before the returned world transform is applied. */
    float x;
    float y;
    float width;
    float height;
    /** Effective ancestor clip in viewport coordinates, after transforms. */
    float clip_x;
    float clip_y;
    float clip_width;
    float clip_height;
    /** Union of direct child bounds, relative to this node's origin. */
    float content_x;
    float content_y;
    float content_width;
    float content_height;
    /** World affine transform using x'=a*x+c*y+tx, y'=b*x+d*y+ty. */
    float transform[6];
    /** First text-line baseline in layout coordinates when HAS_BASELINE is set. */
    float baseline;
    uint32_t reserved[2];
} nkui_layout_item;

/** The size text takes, measured with a layout session's fonts. */
typedef struct nkui_layout_text_measure {
    /** Set to sizeof(nkui_layout_text_measure) when returned by the API. */
    uint32_t struct_size NK_STRUCT_SIZE;
    /** Unwrapped: the advance rounded up to a whole pixel. At a width: that width. */
    float width;
    /** The line height when the paragraph sets one, else the text's height. */
    float height;
    /** The first line's baseline from the top, when `has_baseline` is nonzero. */
    float baseline;
    uint32_t has_baseline;
} nkui_layout_text_measure;

/** Per-submission logical viewport and layout timing. */
typedef struct nkui_layout_frame_input {
    /** Set to sizeof(nkui_layout_frame_input) or a larger compatible size. */
    uint32_t struct_size NK_STRUCT_SIZE;
    float width;
    float height;
    float delta_seconds;
} nkui_layout_frame_input;

/** Creates a private layout session. */
NKUI_API nkui_result NK_CALL nkui_layout_session_create(nkui_layout_session *out_session NKUI_OUT);

/** Destroys a layout session and releases its retained native frame state. */
NKUI_API nkui_result NK_CALL nkui_layout_session_destroy(nkui_layout_session session);

/** Copies the font collection configuration into the layout session. */
NKUI_API nkui_result NK_CALL nkui_layout_session_set_font_collection(nkui_layout_session session,
                                                                     nkui_resource fonts);

/**
 * Measures `text` with the session's fonts: unwrapped when `width` is zero, else laid out at `width`. Laying it out at
 * the width its node is given also shapes it for that node's next submit.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_measure_text(
    nkui_layout_session session, const char *text NKUI_NULLABLE_UTF8, float width,
    const nkui_text_style *text_style, const nkui_paragraph_style *paragraph_style,
    nkui_layout_text_measure *out_measure NKUI_OUT);

/** Clears all custom-paint display lists attached to the session. */
NKUI_API nkui_result NK_CALL nkui_layout_session_clear_custom_paints(nkui_layout_session session);

/** Clears the retained content display list for one custom-visual node. */
NKUI_API nkui_result NK_CALL nkui_layout_session_clear_custom_paint(
    nkui_layout_session session, uint32_t node_id);

/** Clears the retained composite metadata display list for one custom-visual node. */
NKUI_API nkui_result NK_CALL nkui_layout_session_clear_custom_paint_composite(
    nkui_layout_session session, uint32_t node_id);

/**
 * Associates a retained display list with a custom-visual node from the most
 * recently submitted tree. The session retains the list until it is replaced,
 * cleared, or the session is destroyed. Draw commands and clips in the list
 * use node-local coordinates; layout applies the node's position, transform,
 * and ancestor clipping when the list is embedded.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_set_custom_paint(nkui_layout_session session,
                                                                  uint32_t node_id,
                                                                  nkui_display_list display_list);

/**
 * Associates the framework-owned composite metadata for a custom-paint node.
 *
 * The list is expected to contain the layer begin/end pair generated by the
 * UI framework. Its content is composited around the retained custom-paint
 * pixels in node-local coordinates, so changes to opacity, effects, backdrop
 * effects, or masks do not require rebuilding the draw display list.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_set_custom_paint_composite(
    nkui_layout_session session, uint32_t node_id, nkui_display_list display_list);

/** Selects whether a custom-paint plane is rendered as vector content or cached as a raster. */
NKUI_API nkui_result NK_CALL nkui_layout_session_set_custom_paint_cache_policy(
    nkui_layout_session session, uint32_t node_id, nkui_layout_cache_policy policy);

/** Selects whether a render-node subtree is rendered normally or cached as a raster. */
NKUI_API nkui_result NK_CALL nkui_layout_session_set_cache_policy(nkui_layout_session session,
                                                                  uint32_t node_id,
                                                                  nkui_layout_cache_policy policy);

/**
 * Submits one flat, Haxe-owned render/layout tree transaction.
 *
 * The transaction is little-endian and consists of a fixed header, node
 * records of NKUI_LAYOUT_NODE_RECORD_BYTES bytes, and a UTF-8 string table.
 * Node text offsets are absolute byte offsets from the beginning of the
 * transaction. The native side copies all values before returning, so the
 * input buffer may be reused. The transaction is bounded by
 * NKUI_LAYOUT_MAX_TRANSACTION_BYTES; node capacity grows with submitted data.
 * A PATCH_VERSION packet has a 32-byte header: version, updated-node count,
 * record size, string offset, removed-ID count, child-list word count, final
 * node count, and reserved zero. Updated records retain the full record format;
 * their parent field is ignored. After the records come removed uint32 IDs,
 * then child-list blocks (parent ID, child count, ordered child IDs), then UTF-8.
 * Parent zero's sole child is the root. Only changed parents need a block.
 * Patches require a prior successful full submit and are applied atomically.
 * Each node transform is applied about its normalized resolved-box origin;
 * clipped nodes must have an axis-aligned cumulative transform. The default
 * origin is the center of the resolved box.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_submit(
    nkui_layout_session session, const uint8_t *transaction NKUI_IN_ARRAY(transaction_bytes),
    uint32_t transaction_bytes, const nkui_layout_frame_input *frame);

/** Copies resolved geometry in retained tree order. Full submits preserve submission order; patches use child-list preorder.
 *
 * The buffer contains `nkui_layout_item` records with `struct_size` set.
 * Bounds remain in pre-transform layout coordinates; `transform` maps them to
 * viewport coordinates. `clip_*` is the effective inherited clip, and
 * `content_*` describes the union of direct children relative to the node's
 * origin. Pass NULL to query the required byte count, then
 * pass a buffer of that size.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_get_resolved_items(
    nkui_layout_session session, uint8_t *out_buffer NK_OUT_BUFFER(inout_bytes),
    uint32_t *inout_bytes NK_INOUT);

/** Copies only geometry records changed by the last successful submit. Repeated reads return the same records.
 * The first submit exports every record; removals and item order follow the submitted tree, not this update buffer.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_get_resolved_updates(
    nkui_layout_session session, uint8_t *out_buffer NK_OUT_BUFFER(inout_bytes),
    uint32_t *inout_bytes NK_INOUT);

/** Copies changed geometry into caller-owned storage. If capacity is insufficient, no records are written,
 * `out_bytes` receives the required size, and NKUI_ERROR_BUFFER_TOO_SMALL is returned. A zero-capacity
 * buffer may be null. Repeated reads of the same submit return the same records.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_get_resolved_updates_into(
    nkui_layout_session session, uint8_t *buffer NKUI_IN_ARRAY(capacity_bytes), uint32_t capacity_bytes,
    uint32_t *out_bytes NKUI_OUT);

/** Checks every retained native node and its order against a full transaction without changing the session. */
NKUI_API nkui_result NK_CALL nkui_layout_session_verify_tree(
    nkui_layout_session session, const uint8_t *transaction NKUI_IN_ARRAY(transaction_bytes),
    uint32_t transaction_bytes);

/** Executes the submitted layout through the existing NativeKit renderer.
 *
 * The retained UI surface uses on-demand scheduling; request another frame
 * with nk_surface_request_frame() after state, input, or animation changes.
 * When load_existing is non-zero, the layout is composited over the current
 * surface contents instead of clearing the frame first.
 */
NKUI_API nkui_result NK_CALL nkui_layout_session_render_frame(nkui_renderer renderer,
                                                              nkui_layout_session session,
                                                              nk_surface surface,
                                                              const nkui_frame_info *frame_info,
                                                              nk_bool load_existing);

/** Seals the submitted layout as a step for this acquired frame on the platform executor. */
NKUI_API nkui_result NK_CALL nkui_frame_step_layout(
    nkui_renderer renderer, nkui_layout_session session, nk_surface_frame frame,
    const nkui_frame_info *frame_info, nk_bool load_existing,
    nk_surface_frame_step *out_step NKUI_OUT);

#ifdef __cplusplus
}
#endif

#endif
