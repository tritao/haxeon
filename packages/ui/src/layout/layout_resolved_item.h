#ifndef NATIVEKIT_UI_LAYOUT_RESOLVED_ITEM_H
#define NATIVEKIT_UI_LAYOUT_RESOLVED_ITEM_H

#include "nativekit_ui_layout.h"
#include "layout/layout_types.h"

namespace nkui {

inline nkui_layout_item encode_layout_item(const LayoutItem &resolved) {
    nkui_layout_item item{};
    item.struct_size = sizeof(item);
    item.node_id = resolved.id;
    item.flags = (resolved.visible ? NKUI_LAYOUT_RESOLVED_VISIBLE : 0u) |
                 (resolved.has_baseline ? NKUI_LAYOUT_RESOLVED_HAS_BASELINE : 0u);
    item.x = resolved.bounds.x;
    item.y = resolved.bounds.y;
    item.width = resolved.bounds.width;
    item.height = resolved.bounds.height;
    item.clip_x = resolved.clip_bounds.x;
    item.clip_y = resolved.clip_bounds.y;
    item.clip_width = resolved.clip_bounds.width;
    item.clip_height = resolved.clip_bounds.height;
    item.content_x = resolved.content_bounds.x;
    item.content_y = resolved.content_bounds.y;
    item.content_width = resolved.content_bounds.width;
    item.content_height = resolved.content_bounds.height;
    item.transform[0] = resolved.transform.a;
    item.transform[1] = resolved.transform.b;
    item.transform[2] = resolved.transform.c;
    item.transform[3] = resolved.transform.d;
    item.transform[4] = resolved.transform.tx;
    item.transform[5] = resolved.transform.ty;
    item.baseline = resolved.baseline;
    return item;
}

} // namespace nkui
#endif
