#ifndef NATIVEKIT_UI_TESTS_FIXTURE_PLACEMENTS_H
#define NATIVEKIT_UI_TESTS_FIXTURE_PLACEMENTS_H

#include "fixture_geometry.h"
#include "layout/layout_types.h"

namespace fixture {

/** The fixture placement of `nodes`, as the scene builder takes it, in a `width` by `height` viewport. */
inline std::vector<nkui::LayoutPlacement> placements(const std::vector<nkui::LayoutNode> &nodes, float width,
                                                     float height) {
    std::vector<Box> boxes(nodes.size());
    const auto sizing = [](nkui::LayoutSizing value) { return static_cast<uint32_t>(value); };
    for (std::size_t index = 0; index < nodes.size(); ++index) {
        const nkui::LayoutNode &node = nodes[index];
        Box &box = boxes[index];
        box.id = node.id;
        box.parent = node.parent;
        box.width_sizing = sizing(node.style.width.sizing);
        box.height_sizing = sizing(node.style.height.sizing);
        box.width_value = node.style.width.value;
        box.height_value = node.style.height.value;
        box.left_to_right = node.style.direction == nkui::LayoutDirection::LeftToRight;
        box.absolute = node.style.positioning == nkui::LayoutPositioning::Absolute;
        box.text = node.visual_kind == nkui::LayoutVisualKind::Text;
        box.pad_left = node.style.padding_left;
        box.pad_right = node.style.padding_right;
        box.pad_top = node.style.padding_top;
        box.pad_bottom = node.style.padding_bottom;
        box.gap = node.style.child_gap;
        box.position_x = node.style.position_x;
        box.position_y = node.style.position_y;
        box.font_size = node.text_style.font_size;
        box.text_bytes = static_cast<float>(node.text.size());
    }
    solve(boxes, width, height);
    std::vector<nkui::LayoutPlacement> result(boxes.size());
    for (std::size_t index = 0; index < boxes.size(); ++index) {
        const Box &box = boxes[index];
        auto &placement = result[index];
        placement.node_id = box.id;
        placement.bounds = {box.x, box.y, box.width, box.height};
        placement.text_x = box.pad_left;
        placement.text_y = box.pad_top;
        placement.text_width = box.text ? std::max(0.0f, box.width - box.pad_left - box.pad_right) : 0.0f;
        placement.has_baseline = box.text;
        placement.baseline = box.text ? box.y + box.pad_top + box.font_size : 0.0f;
    }
    return result;
}

} // namespace fixture

#endif
