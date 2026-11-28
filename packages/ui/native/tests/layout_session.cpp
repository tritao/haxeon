#include "nativekit_ui_layout.h"
#include "scene_record.h"

#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>

static_assert(NKUI_LAYOUT_NODE_RECORD_BYTES ==
                  NKUI_LAYOUT_NODE_COMPOSITE_REVISION_OFFSET + sizeof(uint32_t),
              "layout node record size must include every defined field");

namespace {

void write_u32(std::vector<uint8_t> &bytes, std::size_t offset, uint32_t value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_i32(std::vector<uint8_t> &bytes, std::size_t offset, int32_t value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_float(std::vector<uint8_t> &bytes, std::size_t offset, float value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_color(std::vector<uint8_t> &bytes, std::size_t offset, float red, float green,
                 float blue, float alpha) {
    write_float(bytes, offset, red);
    write_float(bytes, offset + 4, green);
    write_float(bytes, offset + 8, blue);
    write_float(bytes, offset + 12, alpha);
}

std::vector<uint8_t> transaction() {
    constexpr uint32_t node_count = 3;
    constexpr std::size_t string_offset =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES * node_count;
    const char text[] = "Press";
    std::vector<uint8_t> bytes(string_offset + sizeof(text) - 1);
    write_u32(bytes, 0, NKUI_LAYOUT_TRANSACTION_VERSION);
    write_u32(bytes, 4, node_count);
    write_u32(bytes, 8, NKUI_LAYOUT_NODE_RECORD_BYTES);
    write_u32(bytes, 12, string_offset);

    for (uint32_t index = 0; index < node_count; ++index) {
        const std::size_t offset = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
                                   static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET, 1.0f);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE);
    }

    const auto record = [&](uint32_t index) {
        return NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
               static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
    };
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_ID_OFFSET, 1);
    write_i32(bytes, record(0) + NKUI_LAYOUT_NODE_PARENT_OFFSET, -1);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    fixture::place(bytes.data() + record(0), 0.0f, 0.0f, 256.0f, 192.0f);
    write_color(bytes, record(0) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.1f, 0.1f, 0.1f, 1.0f);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, string_offset);

    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_ID_OFFSET, 2);
    write_i32(bytes, record(1) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 0);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    fixture::place(bytes.data() + record(1), 0.0f, 0.0f, 160.0f, 64.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET, 12.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET, 20.0f);
    write_color(bytes, record(1) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.2f, 0.5f, 0.9f, 1.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, string_offset);

    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_ID_OFFSET, 3);
    write_i32(bytes, record(2) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 1);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_TEXT);
    fixture::place(bytes.data() + record(2), 0.0f, 0.0f, 54.0f, 22.0f, 54.0f, 17.0f);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, string_offset);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_LENGTH_OFFSET, sizeof(text) - 1);
    write_color(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_COLOR_OFFSET, 1.0f, 1.0f, 1.0f, 1.0f);
    write_float(bytes, record(2) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 18.0f);
    std::memcpy(bytes.data() + string_offset, text, sizeof(text) - 1);
    return bytes;
}

std::vector<uint8_t> transaction_with_nodes(uint32_t node_count) {
    const std::size_t string_offset =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES * node_count;
    std::vector<uint8_t> bytes(string_offset);
    write_u32(bytes, 0, NKUI_LAYOUT_TRANSACTION_VERSION);
    write_u32(bytes, 4, node_count);
    write_u32(bytes, 8, NKUI_LAYOUT_NODE_RECORD_BYTES);
    write_u32(bytes, 12, static_cast<uint32_t>(string_offset));
    for (uint32_t index = 0; index < node_count; ++index) {
        const std::size_t offset = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
                                   static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_ID_OFFSET, index + 1);
        write_i32(bytes, offset + NKUI_LAYOUT_NODE_PARENT_OFFSET, index == 0 ? -1 : 0);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
        if (index == 0)
            fixture::place(bytes.data() + offset, 0.0f, 0.0f, 256.0f, 192.0f);
        else
            fixture::place(bytes.data() + offset, 0.0f, static_cast<float>(index - 1), 1.0f, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET, 1.0f);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET,
                  static_cast<uint32_t>(string_offset));
    }
    return bytes;
}


std::vector<uint8_t> patch_from(const std::vector<uint8_t> &full, const std::vector<uint32_t> &indices,
                                const std::vector<uint32_t> &removed = {},
                                const std::vector<uint32_t> &children = {}) {
    uint32_t full_strings = 0, count = 0;
    std::memcpy(&full_strings, full.data() + 12, 4);
    std::memcpy(&count, full.data() + 4, 4);
    const auto strings = NKUI_LAYOUT_PATCH_HEADER_BYTES + indices.size() * NKUI_LAYOUT_NODE_RECORD_BYTES +
        (removed.size() + children.size()) * 4;
    std::vector<uint8_t> result(strings + full.size() - full_strings);
    write_u32(result, 0, NKUI_LAYOUT_PATCH_VERSION);
    write_u32(result, 4, static_cast<uint32_t>(indices.size()));
    write_u32(result, 8, NKUI_LAYOUT_NODE_RECORD_BYTES);
    write_u32(result, 12, static_cast<uint32_t>(strings));
    write_u32(result, 16, static_cast<uint32_t>(removed.size()));
    write_u32(result, 20, static_cast<uint32_t>(children.size()));
    write_u32(result, 24, count);
    for (size_t index = 0; index < indices.size(); ++index) {
        const auto record = NKUI_LAYOUT_PATCH_HEADER_BYTES + index * NKUI_LAYOUT_NODE_RECORD_BYTES;
        const auto source = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + indices[index] * NKUI_LAYOUT_NODE_RECORD_BYTES;
        std::memcpy(result.data() + record, full.data() + source, NKUI_LAYOUT_NODE_RECORD_BYTES);
        uint32_t text = 0;
        std::memcpy(&text, full.data() + source + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, 4);
        write_u32(result, record + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET,
                  static_cast<uint32_t>(strings + text - full_strings));
    }
    auto cursor = NKUI_LAYOUT_PATCH_HEADER_BYTES + indices.size() * NKUI_LAYOUT_NODE_RECORD_BYTES;
    for (const auto id : removed) { write_u32(result, cursor, id); cursor += 4; }
    for (const auto word : children) { write_u32(result, cursor, word); cursor += 4; }
    std::memcpy(result.data() + strings, full.data() + full_strings, full.size() - full_strings);
    return result;
}

std::vector<uint8_t> geometry(nkui_layout_session session, bool updates = false) {
    uint32_t size = 0;
    const auto get = updates ? nkui_layout_session_get_resolved_updates : nkui_layout_session_get_resolved_items;
    if (get(session, nullptr, &size) != NKUI_OK) return {};
    std::vector<uint8_t> result(size);
    if (get(session, result.data(), &size) != NKUI_OK) return {};
    return result;
}

bool incremental(nkui_resource fonts) {
    nkui_layout_session session{}, reference{};
    if (nkui_layout_session_create(&session) != NKUI_OK || nkui_layout_session_create(&reference) != NKUI_OK ||
        nkui_layout_session_set_font_collection(session, fonts) != NKUI_OK ||
        nkui_layout_session_set_font_collection(reference, fonts) != NKUI_OK) return false;
    nkui_layout_frame_input frame{sizeof(frame), 256, 192, 0};
    auto full = transaction_with_nodes(1201);
    const auto submit = [&](nkui_layout_session target, const std::vector<uint8_t> &bytes) {
        return nkui_layout_session_submit(target, bytes.data(), static_cast<uint32_t>(bytes.size()), &frame);
    };
    const auto matches = [&] {
        return nkui_layout_session_verify_tree(session, full.data(), static_cast<uint32_t>(full.size())) == NKUI_OK &&
            submit(reference, full) == NKUI_OK && geometry(session) == geometry(reference);
    };
    if (submit(session, full) != NKUI_OK || !matches() ||
        geometry(session, true).size() != 1201 * NKUI_LAYOUT_RESOLVED_ITEM_BYTES) return false;
    const auto expected_updates = geometry(session, true);
    uint32_t required = 0;
    if (nkui_layout_session_get_resolved_updates_into(session, nullptr, 0, &required) != NKUI_ERROR_BUFFER_TOO_SMALL ||
        required != expected_updates.size()) return false;
    std::vector<uint8_t> update_storage(required, 0xa5);
    uint32_t written = 0;
    if (nkui_layout_session_get_resolved_updates_into(session, nullptr, 1, &written) != NKUI_ERROR_INVALID_ARGUMENT ||
        nkui_layout_session_get_resolved_updates_into(session, update_storage.data(), required, nullptr) !=
            NKUI_ERROR_INVALID_ARGUMENT) return false;
    if (nkui_layout_session_get_resolved_updates_into(session, update_storage.data(), required - 1, &written) !=
            NKUI_ERROR_BUFFER_TOO_SMALL || written != required || update_storage.front() != 0xa5 ||
        update_storage.back() != 0xa5) return false;
    if (nkui_layout_session_get_resolved_updates_into(session, update_storage.data(), required, &written) != NKUI_OK ||
        written != required || update_storage != expected_updates) return false;
    auto patch = patch_from(full, {});
    if (submit(session, patch) != NKUI_OK || !matches() || !geometry(session, true).empty()) return false;
    if (nkui_layout_session_get_resolved_updates_into(session, update_storage.data(), required, &written) != NKUI_OK ||
        written != 0) return false;
    const auto record = [](uint32_t index) { return NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + index * NKUI_LAYOUT_NODE_RECORD_BYTES; };
    // Paint-only, geometry, text/visual-kind and floating layer changes must all match a full solve.
    for (int action = 0; action < 4; ++action) {
        if (action == 0) write_color(full, record(400) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, .3f, .2f, .1f, 1);
        if (action == 1) write_float(full, record(400) + NKUI_LAYOUT_NODE_HEIGHT_OFFSET, 2);
        if (action == 2) {
            write_u32(full, record(400) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_TEXT);
            write_u32(full, record(400) + NKUI_LAYOUT_NODE_TEXT_LENGTH_OFFSET, 5);
            full.insert(full.end(), {'h', 'e', 'l', 'l', 'o'});
        }
        if (action == 3) {
            write_u32(full, record(400) + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE | NKUI_LAYOUT_NODE_FLOATING);
            write_i32(full, record(400) + NKUI_LAYOUT_NODE_Z_INDEX_OFFSET, 12);
        }
        patch = patch_from(full, {400});
        if (submit(session, patch) != NKUI_OK || !matches()) return false;
        const auto changed = geometry(session, true);
        if (changed.size() > geometry(session).size()) return false;
    }
    // Replace an identity and reverse sibling order. Only the new node and the changed parent's list are sent.
    write_u32(full, record(1000) + NKUI_LAYOUT_NODE_ID_OFFSET, 1600);
    std::vector<uint32_t> order{1, 1200};
    for (uint32_t index = 1200; index > 0; --index) {
        uint32_t id = 0; std::memcpy(&id, full.data() + record(index), 4); order.push_back(id);
    }
    patch = patch_from(full, {1000}, {1001}, order);
    // Match the reference's submission order to the declared child order.
    auto reversed = full;
    for (uint32_t index = 1; index <= 1200; ++index)
        std::memcpy(reversed.data() + record(index), full.data() + record(1201 - index), NKUI_LAYOUT_NODE_RECORD_BYTES);
    full.swap(reversed);
    if (submit(session, patch) != NKUI_OK || !matches()) return false;
    // Failed patches leave both the retained input tree and the published snapshot intact.
    const auto before = geometry(session);
    auto invalid = patch_from(full, {1, 1});
    if (submit(session, invalid) != NKUI_ERROR_INVALID_TRANSACTION || !matches() || geometry(session) != before) return false;
    invalid = patch_from(full, {1}, {}, {1, 1, 1}); // changed input plus a cycle/disconnected tree
    write_float(invalid, NKUI_LAYOUT_PATCH_HEADER_BYTES + NKUI_LAYOUT_NODE_WIDTH_OFFSET, 19);
    if (submit(session, invalid) != NKUI_ERROR_INVALID_TRANSACTION || !matches()) return false;
    invalid = patch_from(full, {1});
    write_float(invalid, NKUI_LAYOUT_PATCH_HEADER_BYTES + NKUI_LAYOUT_NODE_WIDTH_OFFSET, -1);
    if (submit(session, invalid) != NKUI_ERROR_INVALID_TRANSACTION || !matches()) return false;
    // This parses successfully, then fails during transformed-clip snapshot construction. Roll back actual changed inputs.
    invalid = patch_from(full, {0});
    const auto root_record = NKUI_LAYOUT_PATCH_HEADER_BYTES;
    write_u32(invalid, root_record + NKUI_LAYOUT_NODE_CLIP_FLAGS_OFFSET, NKUI_LAYOUT_CLIP_HORIZONTAL);
    write_float(invalid, root_record + NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET, .8f);
    write_float(invalid, root_record + NKUI_LAYOUT_NODE_TRANSFORM_B_OFFSET, .6f);
    write_float(invalid, root_record + NKUI_LAYOUT_NODE_TRANSFORM_C_OFFSET, -.6f);
    write_float(invalid, root_record + NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET, .8f);
    if (submit(session, invalid) != NKUI_ERROR_INVALID_TRANSACTION || !matches() || geometry(session) != before) return false;
    patch = patch_from(full, {});
    if (submit(session, patch) != NKUI_OK || !matches()) return false;
    auto wrong_reference = full;
    write_float(wrong_reference, record(1) + NKUI_LAYOUT_NODE_WIDTH_OFFSET, 17);
    if (nkui_layout_session_verify_tree(session, wrong_reference.data(), wrong_reference.size()) != NKUI_ERROR_INVALID_TRANSACTION)
        return false;
    return nkui_layout_session_destroy(session) == NKUI_OK && nkui_layout_session_destroy(reference) == NKUI_OK;
}

} // namespace

int main() {
#ifndef NKUI_TEST_FONT_PATH
    std::cerr << "NKUI_TEST_FONT_PATH is required\n";
    return 2;
#else
    nkui_resource fonts{};
    nkui_layout_session session{};
    if (nkui_font_collection_create(&fonts) != NKUI_OK ||
        nkui_font_collection_add(fonts, NKUI_TEST_FONT_PATH, NKUI_FONT_FAMILY_DEFAULT) != NKUI_OK ||
        nkui_layout_session_create(&session) != NKUI_OK ||
        nkui_layout_session_set_font_collection(session, fonts) != NKUI_OK)
        return 3;

    if (!incremental(fonts)) { std::cerr << "incremental transaction regression\n"; return 90; }

    const auto bytes = transaction();
    nkui_layout_frame_input frame{sizeof(frame), 256.0f, 192.0f, 1.0f / 60.0f};
    uint32_t resolved_bytes = 0;
    if (nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) !=
        NKUI_ERROR_INVALID_ARGUMENT)
        return 12;
    const nkui_result initial_status =
        nkui_layout_session_submit(session, bytes.data(), bytes.size(), &frame);
    if (initial_status != NKUI_OK) {
        std::cerr << "initial submit failed: " << initial_status << "\n";
        return 4;
    }

    // Geometry must be finite, with no negative extent.
    auto invalid_geometry = transaction_with_nodes(2);
    const std::size_t geometry_record = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_float(invalid_geometry, geometry_record + NKUI_LAYOUT_NODE_WIDTH_OFFSET, -1.0f);
    if (nkui_layout_session_submit(session, invalid_geometry.data(), invalid_geometry.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 32;
    write_float(invalid_geometry, geometry_record + NKUI_LAYOUT_NODE_WIDTH_OFFSET, NAN);
    if (nkui_layout_session_submit(session, invalid_geometry.data(), invalid_geometry.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 33;
    write_float(invalid_geometry, geometry_record + NKUI_LAYOUT_NODE_WIDTH_OFFSET, 1.0f);
    write_float(invalid_geometry, geometry_record + NKUI_LAYOUT_NODE_SCROLL_Y_OFFSET, INFINITY);
    if (nkui_layout_session_submit(session, invalid_geometry.data(), invalid_geometry.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 34;

    // Custom-paint lists are retained by their layout session, and only
    // custom-visual nodes in the latest submission may own one.
    auto custom_tree = bytes;
    const std::size_t custom_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(custom_tree, custom_record + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET,
              NKUI_LAYOUT_VISUAL_CUSTOM);
    if (nkui_layout_session_submit(session, custom_tree.data(), custom_tree.size(), &frame) !=
        NKUI_OK)
        return 24;
    nkui_display_list custom_list{};
    if (nkui_display_list_create(&custom_list) != NKUI_OK ||
        nkui_layout_session_set_custom_paint(session, 2, custom_list) != NKUI_OK ||
        nkui_layout_session_set_custom_paint_composite(session, 2, custom_list) != NKUI_OK ||
        nkui_layout_session_set_custom_paint(session, 3, custom_list) !=
            NKUI_ERROR_INVALID_ARGUMENT ||
        nkui_display_list_destroy(custom_list) != NKUI_ERROR_INVALID_ARGUMENT ||
        nkui_layout_session_clear_custom_paint(session, 2) != NKUI_OK ||
        nkui_display_list_destroy(custom_list) != NKUI_ERROR_INVALID_ARGUMENT ||
        nkui_layout_session_clear_custom_paint_composite(session, 2) != NKUI_OK ||
        nkui_display_list_destroy(custom_list) != NKUI_OK)
        return 25;

    if (nkui_display_list_create(&custom_list) != NKUI_OK ||
        nkui_layout_session_set_custom_paint(session, 2, custom_list) != NKUI_OK ||
        nkui_layout_session_submit(session, bytes.data(), bytes.size(), &frame) != NKUI_OK ||
        nkui_display_list_destroy(custom_list) != NKUI_OK)
        return 26;
    if (nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) != NKUI_OK ||
        resolved_bytes != 3 * NKUI_LAYOUT_RESOLVED_ITEM_BYTES)
        return 5;
    std::vector<uint8_t> resolved(resolved_bytes);
    if (nkui_layout_session_get_resolved_items(session, resolved.data(), &resolved_bytes) !=
            NKUI_OK ||
        resolved_bytes != resolved.size())
        return 6;
    nkui_layout_item root_item{};
    nkui_layout_item button_item{};
    nkui_layout_item text_item{};
    std::memcpy(&root_item, resolved.data(), sizeof(root_item));
    std::memcpy(&button_item, resolved.data() + sizeof(root_item), sizeof(button_item));
    std::memcpy(&text_item, resolved.data() + 2 * sizeof(root_item), sizeof(text_item));
    if (root_item.struct_size != sizeof(root_item) || root_item.node_id != 1 ||
        root_item.width != 256.0f || root_item.height != 192.0f ||
        root_item.content_width != 160.0f || root_item.content_height != 64.0f ||
        button_item.node_id != 2 || button_item.width != 160.0f || button_item.height != 64.0f ||
        button_item.transform[4] != 12.0f || button_item.transform[5] != 20.0f ||
        button_item.clip_x != 0.0f || button_item.clip_y != 0.0f ||
        button_item.clip_width != 256.0f || button_item.clip_height != 192.0f ||
        !(button_item.flags & NKUI_LAYOUT_RESOLVED_VISIBLE) || text_item.node_id != 3 ||
        text_item.width <= 0.0f || text_item.height <= 0.0f ||
        !(text_item.flags & NKUI_LAYOUT_RESOLVED_HAS_BASELINE))
        return 10;
    uint32_t undersized_bytes = 1;
    if (nkui_layout_session_get_resolved_items(session, resolved.data(), &undersized_bytes) !=
            NKUI_ERROR_BUFFER_TOO_SMALL ||
        undersized_bytes != resolved.size())
        return 11;

    constexpr uint32_t large_node_count = 2000;
    const auto large = transaction_with_nodes(large_node_count);
    if (large.size() > NKUI_LAYOUT_MAX_TRANSACTION_BYTES ||
        nkui_layout_session_submit(session, large.data(), static_cast<uint32_t>(large.size()),
                                   &frame) != NKUI_OK)
        return 20;
    uint32_t large_resolved_bytes = 0;
    if (nkui_layout_session_get_resolved_items(session, nullptr, &large_resolved_bytes) !=
            NKUI_OK ||
        large_resolved_bytes != large_node_count * NKUI_LAYOUT_RESOLVED_ITEM_BYTES)
        return 21;
    std::vector<uint8_t> large_resolved(large_resolved_bytes);
    if (nkui_layout_session_get_resolved_items(session, large_resolved.data(),
                                               &large_resolved_bytes) != NKUI_OK)
        return 22;
    if (nkui_layout_session_submit(session, large.data(), NKUI_LAYOUT_MAX_TRANSACTION_BYTES + 1u,
                                   &frame) != NKUI_ERROR_INVALID_TRANSACTION)
        return 23;

    resolved_bytes = static_cast<uint32_t>(resolved.size());

    const std::size_t panel_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    auto floating = bytes;
    const std::size_t text_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + 2 * NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(floating, text_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET,
              NKUI_LAYOUT_NODE_VISIBLE | NKUI_LAYOUT_NODE_FLOATING |
                  NKUI_LAYOUT_NODE_CLIP_TO_PARENT);
    fixture::place(floating.data() + text_record, 20.0f, 10.0f, 54.0f, 22.0f, 54.0f, 27.0f);
    write_i32(floating, text_record + NKUI_LAYOUT_NODE_Z_INDEX_OFFSET, 9);
    if (nkui_layout_session_submit(session, floating.data(), floating.size(), &frame) != NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, resolved.data(), &resolved_bytes) !=
            NKUI_OK)
        return 18;
    std::memcpy(&button_item, resolved.data() + sizeof(root_item), sizeof(button_item));
    std::memcpy(&text_item, resolved.data() + 2 * sizeof(root_item), sizeof(text_item));
    if (std::abs(text_item.x - button_item.x - 20.0f) > 0.01f ||
        std::abs(text_item.y - button_item.y - 10.0f) > 0.01f ||
        !(text_item.flags & NKUI_LAYOUT_RESOLVED_VISIBLE))
        return 19;

    auto overlay_transaction = floating;
    write_u32(overlay_transaction, text_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET,
              NKUI_LAYOUT_NODE_VISIBLE | NKUI_LAYOUT_NODE_FLOATING | NKUI_LAYOUT_NODE_OVERLAY);
    if (nkui_layout_session_submit(session, overlay_transaction.data(), overlay_transaction.size(), &frame) != NKUI_OK)
        return 90;
    write_u32(overlay_transaction, text_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET,
              NKUI_LAYOUT_NODE_VISIBLE | NKUI_LAYOUT_NODE_OVERLAY);
    if (nkui_layout_session_submit(session, overlay_transaction.data(), overlay_transaction.size(), &frame) != NKUI_ERROR_INVALID_TRANSACTION)
        return 91;

    auto hidden = bytes;
    write_u32(hidden, panel_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET, 0);
    if (nkui_layout_session_submit(session, hidden.data(), hidden.size(), &frame) != NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, resolved.data(), &resolved_bytes) !=
            NKUI_OK)
        return 14;
    std::memcpy(&button_item, resolved.data() + sizeof(root_item), sizeof(button_item));
    std::memcpy(&text_item, resolved.data() + 2 * sizeof(root_item), sizeof(text_item));
    if ((button_item.flags & NKUI_LAYOUT_RESOLVED_VISIBLE) ||
        (text_item.flags & NKUI_LAYOUT_RESOLVED_VISIBLE))
        return 15;

    auto invalid = bytes;
    write_u32(invalid, 0, NKUI_LAYOUT_TRANSACTION_VERSION + 1);
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 8;
    invalid = bytes;
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE | (1u << 5));
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 13;
    if (nkui_layout_session_destroy(session) != NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) !=
            NKUI_ERROR_INVALID_HANDLE ||
        nkui_resource_destroy(fonts) != NKUI_OK)
        return 9;

    std::cout << "PASS: Haxe layout transaction ABI\n";
    return 0;
#endif
}
