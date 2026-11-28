#ifndef NATIVEKIT_UI_TESTS_FIXTURE_GEOMETRY_H
#define NATIVEKIT_UI_TESTS_FIXTURE_GEOMETRY_H

#include "nativekit_ui_layout.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

/*
 * Geometry for the native tests' fixture trees. The framework lays trees out (ADR 0009); these tests only need boxes
 * where their fixtures expect them, so this places the small trees they build: fixed sizes, percent and grow of the
 * parent's inner size, fit to children, children stacked along their parent's direction after its padding and with its
 * gap, absolute nodes at their position from the parent, and text one line high at an advance of 0.6 em per byte, with
 * its baseline an em below its top.
 */
namespace fixture {

struct Box {
    uint32_t id = 0;
    int32_t parent = -1;
    uint32_t width_sizing = 0, height_sizing = 0;
    float width_value = 0, height_value = 0;
    bool left_to_right = false, absolute = false, text = false;
    float pad_left = 0, pad_right = 0, pad_top = 0, pad_bottom = 0, gap = 0;
    float position_x = 0, position_y = 0, font_size = 16, text_bytes = 0;
    float x = 0, y = 0, width = 0, height = 0;
};

inline uint32_t read_u32(const uint8_t *bytes, std::size_t offset) {
    uint32_t value = 0;
    std::memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

inline float read_float(const uint8_t *bytes, std::size_t offset) {
    float value = 0;
    std::memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

inline float fit(const std::vector<Box> &boxes, std::size_t index, bool horizontal) {
    const Box &box = boxes[index];
    float content = 0;
    std::size_t flow = 0;
    const bool main = horizontal == box.left_to_right;
    for (std::size_t child = 0; child < boxes.size(); ++child) {
        if (boxes[child].parent != static_cast<int32_t>(index) || boxes[child].absolute)
            continue;
        const float size = horizontal ? boxes[child].width : boxes[child].height;
        content = main ? content + size : std::max(content, size);
        ++flow;
    }
    if (main && flow > 1)
        content += box.gap * static_cast<float>(flow - 1);
    if (box.text)
        content = std::max(content, horizontal ? std::ceil(box.text_bytes * box.font_size * 0.6f)
                                               : std::ceil(box.font_size * 1.25f));
    return content + (horizontal ? box.pad_left + box.pad_right : box.pad_top + box.pad_bottom);
}

inline void solve(std::vector<Box> &boxes, float width, float height);

/** Places a full transaction's tree in a `width` by `height` viewport. */
inline std::vector<Box> place(const uint8_t *transaction, float width, float height) {
    const uint32_t count = read_u32(transaction, 4);
    const uint32_t record_bytes = read_u32(transaction, 8);
    std::vector<Box> boxes(count);
    for (uint32_t index = 0; index < count; ++index) {
        const uint8_t *record = transaction + NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + index * record_bytes;
        Box &box = boxes[index];
        box.id = read_u32(record, NKUI_LAYOUT_NODE_ID_OFFSET);
        std::memcpy(&box.parent, record + NKUI_LAYOUT_NODE_PARENT_OFFSET, sizeof(box.parent));
        box.width_sizing = read_u32(record, NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET);
        box.height_sizing = read_u32(record, NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET);
        box.width_value = read_float(record, NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET);
        box.height_value = read_float(record, NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET);
        box.left_to_right = read_u32(record, NKUI_LAYOUT_NODE_DIRECTION_OFFSET) == NKUI_LAYOUT_DIRECTION_LEFT_TO_RIGHT;
        box.absolute = (read_u32(record, NKUI_LAYOUT_NODE_FLAGS_OFFSET) & NKUI_LAYOUT_NODE_FLOATING) != 0;
        box.text = read_u32(record, NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET) == NKUI_LAYOUT_VISUAL_TEXT;
        box.pad_left = read_float(record, NKUI_LAYOUT_NODE_PADDING_LEFT_OFFSET);
        box.pad_right = read_float(record, NKUI_LAYOUT_NODE_PADDING_RIGHT_OFFSET);
        box.pad_top = read_float(record, NKUI_LAYOUT_NODE_PADDING_TOP_OFFSET);
        box.pad_bottom = read_float(record, NKUI_LAYOUT_NODE_PADDING_BOTTOM_OFFSET);
        box.gap = read_float(record, NKUI_LAYOUT_NODE_CHILD_GAP_OFFSET);
        box.position_x = read_float(record, NKUI_LAYOUT_NODE_POSITION_X_OFFSET);
        box.position_y = read_float(record, NKUI_LAYOUT_NODE_POSITION_Y_OFFSET);
        box.font_size = read_float(record, NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET);
        box.text_bytes = static_cast<float>(read_u32(record, NKUI_LAYOUT_NODE_TEXT_LENGTH_OFFSET));
    }
    solve(boxes, width, height);
    return boxes;
}

/** Fit sizes bottom up, then sizes and positions top down: children come after their parents in these fixtures. */
inline void solve(std::vector<Box> &boxes, float width, float height) {
    for (std::size_t index = boxes.size(); index-- > 0;) {
        Box &box = boxes[index];
        box.width = box.width_sizing == NKUI_LAYOUT_SIZING_FIXED ? box.width_value : fit(boxes, index, true);
        box.height = box.height_sizing == NKUI_LAYOUT_SIZING_FIXED ? box.height_value : fit(boxes, index, false);
    }
    for (std::size_t index = 0; index < boxes.size(); ++index) {
        Box &box = boxes[index];
        if (box.parent < 0) {
            if (box.width_sizing == NKUI_LAYOUT_SIZING_GROW || box.width_sizing == NKUI_LAYOUT_SIZING_PERCENT)
                box.width = box.width_sizing == NKUI_LAYOUT_SIZING_PERCENT ? width * box.width_value : width;
            if (box.height_sizing == NKUI_LAYOUT_SIZING_GROW || box.height_sizing == NKUI_LAYOUT_SIZING_PERCENT)
                box.height = box.height_sizing == NKUI_LAYOUT_SIZING_PERCENT ? height * box.height_value : height;
        }
        const float inner_width = std::max(0.0f, box.width - box.pad_left - box.pad_right);
        const float inner_height = std::max(0.0f, box.height - box.pad_top - box.pad_bottom);
        float cursor = 0;
        for (std::size_t child = index + 1; child < boxes.size(); ++child) {
            Box &item = boxes[child];
            if (item.parent != static_cast<int32_t>(index))
                continue;
            if (item.width_sizing == NKUI_LAYOUT_SIZING_PERCENT)
                item.width = inner_width * item.width_value;
            else if (item.width_sizing == NKUI_LAYOUT_SIZING_GROW)
                item.width = box.left_to_right && !item.absolute ? std::max(0.0f, inner_width - cursor) : inner_width;
            if (item.height_sizing == NKUI_LAYOUT_SIZING_PERCENT)
                item.height = inner_height * item.height_value;
            else if (item.height_sizing == NKUI_LAYOUT_SIZING_GROW)
                item.height = !box.left_to_right && !item.absolute ? std::max(0.0f, inner_height - cursor) : inner_height;
            if (item.absolute) {
                item.x = box.x + item.position_x;
                item.y = box.y + item.position_y;
                continue;
            }
            item.x = box.x + box.pad_left + (box.left_to_right ? cursor : 0.0f);
            item.y = box.y + box.pad_top + (box.left_to_right ? 0.0f : cursor);
            cursor += (box.left_to_right ? item.width : item.height) + box.gap;
        }
    }
}

/** `nkui_layout_session_set_geometry`'s records for a full transaction's tree. */
inline std::vector<uint8_t> geometry(const uint8_t *transaction, float width, float height) {
    const auto boxes = place(transaction, width, height);
    std::vector<uint8_t> bytes(boxes.size() * NKUI_LAYOUT_GEOMETRY_RECORD_BYTES);
    for (std::size_t index = 0; index < boxes.size(); ++index) {
        uint8_t *record = bytes.data() + index * NKUI_LAYOUT_GEOMETRY_RECORD_BYTES;
        const Box &box = boxes[index];
        const float none = std::nanf("");
        const float values[] = {box.x, box.y, box.width, box.height, box.pad_left, box.pad_top,
                                box.text ? std::max(0.0f, box.width - box.pad_left - box.pad_right) : 0.0f,
                                box.text ? box.y + box.pad_top + box.font_size : none};
        std::memcpy(record + NKUI_LAYOUT_GEOMETRY_NODE_ID_OFFSET, &box.id, sizeof(box.id));
        std::memcpy(record + NKUI_LAYOUT_GEOMETRY_X_OFFSET, values, sizeof(values));
    }
    return bytes;
}

/** Sets the fixture geometry of a full transaction and submits it. */
inline nkui_result submit(nkui_layout_session session, const uint8_t *transaction, uint32_t bytes,
                          const nkui_layout_frame_input *frame) {
    const auto placed = geometry(transaction, frame->width, frame->height);
    const nkui_result status =
        nkui_layout_session_set_geometry(session, placed.data(), static_cast<uint32_t>(placed.size()));
    return status != NKUI_OK ? status : nkui_layout_session_submit(session, transaction, bytes, frame);
}

} // namespace fixture

#endif
