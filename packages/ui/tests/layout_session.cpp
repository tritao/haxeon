#include "nativekit_ui_layout.h"

#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>

static_assert(NKUI_LAYOUT_NODE_RECORD_BYTES ==
                  NKUI_LAYOUT_NODE_TAB_WIDTH_OFFSET + sizeof(uint32_t),
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
        write_float(bytes, offset + NKUI_LAYOUT_NODE_WIDTH_GROW_WEIGHT_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_HEIGHT_GROW_WEIGHT_OFFSET, 1.0f);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE);
    }

    const auto record = [&](uint32_t index) {
        return NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
               static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
    };
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_ID_OFFSET, 1);
    write_i32(bytes, record(0) + NKUI_LAYOUT_NODE_PARENT_OFFSET, -1);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 256.0f);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 192.0f);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
    write_color(bytes, record(0) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.1f, 0.1f, 0.1f, 1.0f);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, string_offset);

    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_ID_OFFSET, 2);
    write_i32(bytes, record(1) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 0);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 160.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 64.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET, 12.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET, 20.0f);
    write_color(bytes, record(1) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.2f, 0.5f, 0.9f, 1.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET, string_offset);

    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_ID_OFFSET, 3);
    write_i32(bytes, record(2) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 1);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_TEXT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
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
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET,
                    index == 0 ? 256.0f : 1.0f);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET,
                    index == 0 ? 192.0f : 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_WIDTH_GROW_WEIGHT_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_HEIGHT_GROW_WEIGHT_OFFSET, 1.0f);
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
    auto patch = patch_from(full, {});
    if (submit(session, patch) != NKUI_OK || !matches() || !geometry(session, true).empty()) return false;
    const auto record = [](uint32_t index) { return NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + index * NKUI_LAYOUT_NODE_RECORD_BYTES; };
    // Paint-only, geometry, text/visual-kind and floating layer changes must all match a full solve.
    for (int action = 0; action < 4; ++action) {
        if (action == 0) write_color(full, record(400) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, .3f, .2f, .1f, 1);
        if (action == 1) write_float(full, record(400) + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 2);
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
    write_float(invalid, NKUI_LAYOUT_PATCH_HEADER_BYTES + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 19);
    if (submit(session, invalid) != NKUI_ERROR_INVALID_TRANSACTION || !matches()) return false;
    invalid = patch_from(full, {1});
    write_float(invalid, NKUI_LAYOUT_PATCH_HEADER_BYTES + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, -1);
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
    write_float(wrong_reference, record(1) + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 17);
    if (nkui_layout_session_verify_tree(session, wrong_reference.data(), wrong_reference.size()) != NKUI_ERROR_INVALID_TRANSACTION)
        return false;
    return nkui_layout_session_destroy(session) == NKUI_OK && nkui_layout_session_destroy(reference) == NKUI_OK;
}

struct MeasureState {
    uint32_t calls = 0;
    nkui_layout_session session{};
    nkui_result reentrant_stats = NKUI_OK;
    nkui_result unrelated_list = NKUI_ERROR_OUT_OF_MEMORY;
};

nkui_layout_measure_result measure_custom_node(uint32_t node_id,
                                               nkui_layout_measure_constraints constraints,
                                               void *user_data) {
    auto *state = static_cast<MeasureState *>(user_data);
    if (state) {
        ++state->calls;
        nkui_layout_measure_stats stats{sizeof(stats)};
        state->reentrant_stats = nkui_layout_session_get_measure_stats(state->session, &stats);
        nkui_display_list list{};
        state->unrelated_list = nkui_display_list_create(&list);
        if (state->unrelated_list == NKUI_OK)
            state->unrelated_list = nkui_display_list_destroy(list);
    }
    if (node_id != 2)
        return {sizeof(nkui_layout_measure_result), 0.0f, 0.0f, 0.0f, 0};
    return {sizeof(nkui_layout_measure_result), 48.0f, 20.0f, 15.0f,
            NKUI_LAYOUT_MEASURE_HAS_BASELINE};
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

    MeasureState measure_state;
    measure_state.session = session;
    if (nkui_layout_session_set_measure_callback(session, measure_custom_node, &measure_state) !=
        NKUI_OK)
        return 43;

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

    uint32_t hit_bytes = 0;
    if (nkui_layout_session_hit_test(session, 250.0f, 180.0f, nullptr, &hit_bytes) != NKUI_OK ||
        hit_bytes != sizeof(uint32_t))
        return 52;
    uint32_t hit_path[2] = {};
    uint32_t undersized_hit_bytes = 0;
    if (nkui_layout_session_hit_test(session, 250.0f, 180.0f,
                                      reinterpret_cast<uint8_t *>(hit_path),
                                      &undersized_hit_bytes) != NKUI_ERROR_INVALID_ARGUMENT ||
        undersized_hit_bytes != sizeof(uint32_t))
        return 53;
    hit_bytes = sizeof(hit_path);
    if (nkui_layout_session_hit_test(session, 250.0f, 180.0f,
                                      reinterpret_cast<uint8_t *>(hit_path), &hit_bytes) != NKUI_OK ||
        hit_bytes != sizeof(uint32_t) || hit_path[0] != 1)
        return 54;

    hit_bytes = 0;
    if (nkui_layout_session_hit_test(session, 150.0f, 75.0f, nullptr, &hit_bytes) != NKUI_OK ||
        hit_bytes != 2 * sizeof(uint32_t))
        return 55;
    hit_bytes = 2 * sizeof(uint32_t);
    if (nkui_layout_session_hit_test(session, 150.0f, 75.0f,
                                      reinterpret_cast<uint8_t *>(hit_path), &hit_bytes) != NKUI_OK ||
        hit_bytes != 2 * sizeof(uint32_t) || hit_path[0] != 1 || hit_path[1] != 2)
        return 56;

    uint32_t hit_path_storage[2] = {};
    uint32_t hit_count = 0;
    if (nkui_layout_session_hit_test_into(session, 150.0f, 75.0f,
                                           reinterpret_cast<uint8_t *>(hit_path_storage),
                                           sizeof(hit_path_storage), &hit_count) != NKUI_OK ||
        hit_count != 2 || hit_path_storage[0] != 1 || hit_path_storage[1] != 2)
        return 59;
    uint8_t undersized_hit_path[sizeof(uint32_t)] = {};
    hit_count = 0;
    if (nkui_layout_session_hit_test_into(session, 150.0f, 75.0f, undersized_hit_path,
                                           sizeof(undersized_hit_path), &hit_count) !=
            NKUI_ERROR_INVALID_ARGUMENT ||
        hit_count != 2)
        return 60;

    auto hidden_hit = bytes;
    const std::size_t hidden_panel_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(hidden_hit, hidden_panel_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET, 0);
    if (nkui_layout_session_submit(session, hidden_hit.data(), hidden_hit.size(), &frame) !=
            NKUI_OK ||
        nkui_layout_session_hit_test(session, 150.0f, 75.0f, nullptr, &hit_bytes) != NKUI_OK ||
        hit_bytes != sizeof(uint32_t))
        return 57;
    nkui_layout_hit_test_stats hit_stats{};
    if (nkui_layout_session_get_hit_test_stats(session, &hit_stats) != NKUI_OK ||
        hit_stats.struct_size != sizeof(hit_stats) || hit_stats.hit_test_count < 6 ||
        hit_stats.nodes_visited < hit_stats.hit_test_count || hit_stats.precise_hit_tests == 0 ||
        hit_stats.max_nodes_visited == 0 || hit_stats.hit_test_time_nanoseconds == 0)
        return 58;

    auto constraints = transaction_with_nodes(2);
    const std::size_t constraints_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIT);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MIN_OFFSET, 40.0f);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MAX_OFFSET, 80.0f);
    write_u32(constraints, constraints_record + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIXED);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 30.0f);
    if (nkui_layout_session_submit(session, constraints.data(), constraints.size(), &frame) !=
            NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) != NKUI_OK)
        return 27;
    std::vector<uint8_t> constraints_resolved(resolved_bytes);
    if (nkui_layout_session_get_resolved_items(session, constraints_resolved.data(),
                                               &resolved_bytes) != NKUI_OK)
        return 28;
    nkui_layout_item constrained_item{};
    std::memcpy(&constrained_item, constraints_resolved.data() + sizeof(nkui_layout_item),
                sizeof(constrained_item));
    if (constrained_item.width < 40.0f || constrained_item.width > 80.0f ||
        constrained_item.height != 30.0f)
        return 29;

    write_u32(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIXED);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 80.0f);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MIN_OFFSET, 0.0f);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MAX_OFFSET, 0.0f);
    write_u32(constraints, constraints_record + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIT);
    write_float(constraints, constraints_record + NKUI_LAYOUT_NODE_ASPECT_RATIO_OFFSET, 2.0f);
    if (nkui_layout_session_submit(session, constraints.data(), constraints.size(), &frame) !=
            NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, constraints_resolved.data(),
                                               &resolved_bytes) != NKUI_OK)
        return 30;
    std::memcpy(&constrained_item, constraints_resolved.data() + sizeof(nkui_layout_item),
                sizeof(constrained_item));
    if (std::abs(constrained_item.width - 80.0f) > 0.01f ||
        std::abs(constrained_item.height - 40.0f) > 0.01f)
        return 31;

    auto invalid_constraints = constraints;
    write_float(invalid_constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MAX_OFFSET, 79.0f);
    write_float(invalid_constraints, constraints_record + NKUI_LAYOUT_NODE_WIDTH_MIN_OFFSET, 80.0f);
    if (nkui_layout_session_submit(session, invalid_constraints.data(), invalid_constraints.size(),
                                   &frame) != NKUI_ERROR_INVALID_TRANSACTION)
        return 32;

    auto invalid_weight = constraints;
    write_u32(invalid_weight, constraints_record + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_GROW);
    write_float(invalid_weight, constraints_record + NKUI_LAYOUT_NODE_WIDTH_GROW_WEIGHT_OFFSET,
                0.0f);
    if (nkui_layout_session_submit(session, invalid_weight.data(), invalid_weight.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 33;
    write_float(invalid_weight, constraints_record + NKUI_LAYOUT_NODE_WIDTH_GROW_WEIGHT_OFFSET,
                NAN);
    if (nkui_layout_session_submit(session, invalid_weight.data(), invalid_weight.size(), &frame) !=
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
    if (measure_state.calls == 0 || measure_state.reentrant_stats != NKUI_ERROR_INVALID_ARGUMENT ||
        measure_state.unrelated_list != NKUI_OK)
        return 41;
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
            NKUI_ERROR_INVALID_ARGUMENT ||
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

    auto centered = bytes;
    const std::size_t panel_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(centered, panel_record + NKUI_LAYOUT_NODE_CHILD_ALIGNMENT_OFFSET,
              NKUI_LAYOUT_ALIGNMENT_CENTER | (NKUI_LAYOUT_ALIGNMENT_CENTER << 8));
    write_u32(centered, panel_record + NKUI_LAYOUT_NODE_CHILD_DISTRIBUTION_OFFSET,
              NKUI_LAYOUT_DISTRIBUTION_CENTER);
    if (nkui_layout_session_submit(session, centered.data(), centered.size(), &frame) != NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, resolved.data(), &resolved_bytes) !=
            NKUI_OK)
        return 16;
    std::memcpy(&button_item, resolved.data() + sizeof(root_item), sizeof(button_item));
    std::memcpy(&text_item, resolved.data() + 2 * sizeof(root_item), sizeof(text_item));
    if (std::abs(text_item.x - (button_item.x + (button_item.width - text_item.width) * 0.5f)) >
            0.01f ||
        std::abs(text_item.y - (button_item.y + (button_item.height - text_item.height) * 0.5f)) >
            0.01f)
        return 17;

    measure_state.calls = 0;
    auto measured = transaction_with_nodes(2);
    const std::size_t measured_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(measured, measured_record + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET,
              NKUI_LAYOUT_VISUAL_CUSTOM);
    write_u32(measured, measured_record + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIT);
    write_u32(measured, measured_record + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET,
              NKUI_LAYOUT_SIZING_FIT);
    if (nkui_layout_session_submit(session, measured.data(), measured.size(), &frame) != NKUI_OK ||
        measure_state.calls != 1 ||
        nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) != NKUI_OK)
        return 44;
    std::vector<uint8_t> measured_resolved(resolved_bytes);
    if (nkui_layout_session_get_resolved_items(session, measured_resolved.data(),
                                               &resolved_bytes) != NKUI_OK)
        return 45;
    std::memcpy(&button_item, measured_resolved.data() + sizeof(root_item), sizeof(button_item));
    if (button_item.width != 48.0f || button_item.height != 20.0f ||
        !(button_item.flags & NKUI_LAYOUT_RESOLVED_HAS_BASELINE) ||
        std::abs(button_item.baseline - 15.0f) > 0.01f)
        return 46;
    if (nkui_layout_session_submit(session, measured.data(), measured.size(), &frame) != NKUI_OK ||
        measure_state.calls != 1)
        return 47;
    nkui_layout_measure_stats measure_stats{};
    if (nkui_layout_session_get_measure_stats(session, &measure_stats) != NKUI_OK ||
        measure_stats.struct_size != sizeof(measure_stats) || measure_stats.requests < 2 ||
        measure_stats.cache_hits == 0 || measure_stats.cache_misses == 0 ||
        measure_stats.callback_calls < measure_state.calls || measure_stats.cache_entries == 0 ||
        measure_stats.cache_capacity < measure_stats.cache_entries)
        return 50;
    write_u32(measured, measured_record + NKUI_LAYOUT_NODE_MEASURE_VERSION_OFFSET, 1);
    if (nkui_layout_session_submit(session, measured.data(), measured.size(), &frame) != NKUI_OK ||
        measure_state.calls != 2)
        return 49;
    if (nkui_layout_session_get_measure_stats(session, &measure_stats) != NKUI_OK ||
        measure_stats.cache_misses < 2 || measure_stats.callback_calls < measure_state.calls)
        return 51;
    if (nkui_layout_session_set_measure_callback(session, nullptr, nullptr) != NKUI_OK)
        return 48;
    resolved_bytes = static_cast<uint32_t>(resolved.size());

    auto floating = bytes;
    const std::size_t text_record =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + 2 * NKUI_LAYOUT_NODE_RECORD_BYTES;
    write_u32(floating, text_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET,
              NKUI_LAYOUT_NODE_VISIBLE | NKUI_LAYOUT_NODE_FLOATING |
                  NKUI_LAYOUT_NODE_CLIP_TO_PARENT);
    write_float(floating, text_record + NKUI_LAYOUT_NODE_POSITION_X_OFFSET, 20.0f);
    write_float(floating, text_record + NKUI_LAYOUT_NODE_POSITION_Y_OFFSET, 10.0f);
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

    auto baseline = bytes;
    write_u32(baseline, panel_record + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_LEFT_TO_RIGHT);
    write_u32(baseline, panel_record + NKUI_LAYOUT_NODE_CHILD_ALIGNMENT_OFFSET,
              NKUI_LAYOUT_ALIGNMENT_CENTER | (NKUI_LAYOUT_ALIGNMENT_BASELINE << 8));
    if (nkui_layout_session_submit(session, baseline.data(), baseline.size(), &frame) != NKUI_OK)
        return 36;

    auto wrapped = bytes;
    write_u32(wrapped, panel_record + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_LEFT_TO_RIGHT);
    write_u32(wrapped, panel_record + NKUI_LAYOUT_NODE_WRAP_MODE_OFFSET, NKUI_LAYOUT_WRAP_WRAP);
    write_float(wrapped, panel_record + NKUI_LAYOUT_NODE_ROW_GAP_OFFSET, 6.5f);
    write_float(wrapped, panel_record + NKUI_LAYOUT_NODE_COLUMN_GAP_OFFSET, 4.25f);
    write_u32(wrapped, panel_record + NKUI_LAYOUT_NODE_ALIGN_SELF_OFFSET,
              NKUI_LAYOUT_SELF_ALIGNMENT_CENTER);
    if (nkui_layout_session_submit(session, wrapped.data(), wrapped.size(), &frame) != NKUI_OK)
        return 38;

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
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_CHILD_ALIGNMENT_OFFSET,
              NKUI_LAYOUT_ALIGNMENT_BASELINE | (NKUI_LAYOUT_ALIGNMENT_CENTER << 8));
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 13;
    invalid = bytes;
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_CHILD_ALIGNMENT_OFFSET,
              NKUI_LAYOUT_ALIGNMENT_CENTER | ((NKUI_LAYOUT_ALIGNMENT_BASELINE + 1u) << 8));
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 37;
    invalid = bytes;
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_CHILD_DISTRIBUTION_OFFSET,
              NKUI_LAYOUT_DISTRIBUTION_SPACE_EVENLY + 1u);
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 35;
    invalid = bytes;
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_WRAP_MODE_OFFSET,
              NKUI_LAYOUT_WRAP_WRAP + 1u);
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 39;
    invalid = bytes;
    write_u32(invalid, panel_record + NKUI_LAYOUT_NODE_ALIGN_SELF_OFFSET,
              NKUI_LAYOUT_SELF_ALIGNMENT_BASELINE + 1u);
    if (nkui_layout_session_submit(session, invalid.data(), invalid.size(), &frame) !=
        NKUI_ERROR_INVALID_TRANSACTION)
        return 40;
    if (nkui_layout_session_destroy(session) != NKUI_OK ||
        nkui_layout_session_get_resolved_items(session, nullptr, &resolved_bytes) !=
            NKUI_ERROR_INVALID_HANDLE ||
        nkui_resource_destroy(fonts) != NKUI_OK)
        return 9;

    std::cout << "PASS: Haxe layout transaction ABI\n";
    return 0;
#endif
}
