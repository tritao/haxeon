#include "linear_layout_engine.h"
#include "layout/layout_id_index.h"
#include "layout/layout_cost.h"
#include "layout/layout_resolved_item.h"

#include <cstdio>
#include <cstring>
#include <iostream>
#include <vector>

using namespace nkui;

namespace {

std::vector<LayoutNode> fixture() {
    std::vector<LayoutNode> nodes(1201);
    auto &root = nodes[0];
    root.id = 1;
    root.style.width = {LayoutSizing::Fixed, 1200};
    root.style.height = {LayoutSizing::Fixed, 900};
    root.style.direction = LayoutDirection::TopToBottom;
    root.style.clip_horizontal = true;
    root.style.clip_vertical = true;
    for (std::size_t row = 0; row < 600; ++row) {
        auto &box = nodes[1 + row * 2];
        box.id = static_cast<uint32_t>(0x10000 + row * 43);
        box.parent = 0;
        box.style.width = {LayoutSizing::Fixed, 200};
        box.style.height = {LayoutSizing::Fixed, 22};
        box.style.background = {0.2f, 0.3f, 0.4f, 1};
        box.style.transform.tx = static_cast<float>(row % 4);
        if (row % 11 == 0) {
            box.style.positioning = LayoutPositioning::Absolute;
            box.style.position_y = static_cast<float>(row);
            box.style.overlay = row % 22 == 0;
            box.style.z_index = static_cast<int32_t>(row % 7) - 3;
        }
        auto &text = nodes[2 + row * 2];
        text.id = box.id + 1;
        text.parent = static_cast<int32_t>(1 + row * 2);
        text.visual_kind = LayoutVisualKind::Text;
        text.text = "Snapshot label " + std::to_string(row);
        text.style.width = {LayoutSizing::Fixed, 180};
        text.text_color = {1, 1, 1, 1};
        text.text_style.font_size = 12;
    }
    return nodes;
}

bool equal_snapshots(const LayoutSnapshot &indexed, const LayoutSnapshot &linear) {
    // Defaulted equality covers every field of all snapshot payloads, including text bytes and line order.
    if (!(indexed == linear)) return false;
    for (std::size_t index = 0; index < indexed.items.size(); ++index) {
        const auto actual = encode_layout_item(indexed.items[index]);
        const auto expected = encode_layout_item(linear.items[index]);
        if (std::memcmp(&actual, &expected, sizeof(actual))) return false;
    }
    return true;
}

bool index_invariants() {
    LayoutIdIndex index;
    index.reset(1201);
    for (uint64_t id = 1; id <= 1201; ++id) index.insert(id * 65537, static_cast<std::size_t>(id));
    for (uint64_t id = 1; id <= 1201; ++id)
        if (index.find(id * 65537) != id) return false;
    index.insert(65537, 17);
    if (index.find(65537) != 1 || index.find(0) != LayoutIdIndex::missing ||
        index.find(42) != LayoutIdIndex::missing) return false;
    index.reset(0);
    if (index.find(65537) != LayoutIdIndex::missing) return false;
    index.reset(1); index.insert(UINT64_MAX, 4);
    return index.find(UINT64_MAX) == 4 && index.find(65537) == LayoutIdIndex::missing;
}

} // namespace

int main() {
    if (!index_invariants()) return 1;
    LayoutEngine indexed(4096);
    LinearLayoutEngine linear(4096);
    if (!indexed.valid() || !linear.valid() || !indexed.add_font(NKUI_TEST_FONT_PATH) ||
        !linear.add_font(NKUI_TEST_FONT_PATH)) return 2;
    auto nodes = fixture();
    LayoutSnapshot actual, expected;
    LayoutError error{};
    for (int frame = 0; frame < 104; ++frame) {
        // Exercise baselines, transforms, clipping, floating layers and text changes on the same large tree.
        if (frame == 52) {
            nodes[14].text = "Changed 日本語 label";
            nodes[15].style.transform.ty = 3;
        }
        if (layout_cost_enabled()) std::fprintf(stderr, "snapshot-index engine=linear frame=%d\n", frame);
        if (!linear.layout(nodes, 1200, 900, 0.016f, expected, &error)) {
            std::cerr << "linear: " << (error.message ? error.message : "failure") << '\n'; return 3;
        }
        if (layout_cost_enabled()) std::fprintf(stderr, "snapshot-index engine=indexed frame=%d\n", frame);
        if (!indexed.layout(nodes, 1200, 900, 0.016f, actual, &error)) {
            std::cerr << "indexed: " << (error.message ? error.message : "failure") << '\n'; return 4;
        }
        if (!equal_snapshots(actual, expected)) {
            std::cerr << "snapshot differs at frame " << frame << '\n'; return 5;
        }
    }
    if (actual.items.size() != 1201 || actual.text_layouts.size() < 500) return 6;
    std::cout << "PASS: complete snapshot equality and byte-identical resolved records against linear lookups on 1201 nodes\n";
    return 0;
}
