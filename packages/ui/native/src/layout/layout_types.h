#ifndef NATIVEKIT_UI_LAYOUT_TYPES_H
#define NATIVEKIT_UI_LAYOUT_TYPES_H

#include <algorithm>
#include <cstdint>
#include <cstddef>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace nkui {

struct LayoutInputChanges {
    bool topology = true;
    bool layers = true;
    bool topology_validated = false;
    std::vector<std::size_t> nodes;
};

enum class LayoutVisualKind : uint8_t {
    Box = 1,
    Text,
    Image,
    Custom,
};

// NativeKit-owned font family selector. Concrete text engines translate this
// value to their own font collection model.
enum class FontFamily : uint8_t {
    Default = 0,
    Emoji = 1,
    Monospace = 4,
};

enum class TextWrapMode : uint8_t {
    None = 0,
    Word,
    WordCharacter,
};

enum class TextAlignment : uint8_t {
    Start = 0,
    Center,
    End,
};

enum class TextDirection : uint8_t {
    Auto = 0,
    Ltr,
    Rtl,
};

struct TextStyle {
    bool operator==(const TextStyle &) const = default;
    FontFamily family = FontFamily::Default;
    float font_size = 16.0f;
    float letter_spacing = 0.0f;
};

struct ParagraphStyle {
    bool operator==(const ParagraphStyle &) const = default;
    TextWrapMode wrap = TextWrapMode::WordCharacter;
    TextAlignment alignment = TextAlignment::Start;
    float line_height = 0.0f;
    uint32_t tab_width = 0;
    TextDirection direction = TextDirection::Auto;
};

using TextLayoutId = uint64_t;

enum class LayoutPositioning : uint8_t {
    Flow = 0,
    Absolute,
};

struct LayoutColor {
    bool operator==(const LayoutColor &) const = default;
    float red = 0.0f;
    float green = 0.0f;
    float blue = 0.0f;
    float alpha = 0.0f;
};

struct LayoutTransform {
    bool operator==(const LayoutTransform &) const = default;
    float a = 1.0f;
    float b = 0.0f;
    float c = 0.0f;
    float d = 1.0f;
    float tx = 0.0f;
    float ty = 0.0f;
};

struct LayoutRect {
    bool operator==(const LayoutRect &) const = default;
    float x = 0.0f;
    float y = 0.0f;
    float width = 0.0f;
    float height = 0.0f;
};

/** How a node paints and stacks; where it is comes from its placement. */
struct LayoutStyle {
    bool operator==(const LayoutStyle &) const = default;
    LayoutPositioning positioning = LayoutPositioning::Flow;
    int32_t z_index = 0;
    bool clip_to_parent = true;
    bool overlay = false;
    LayoutColor background{};
    float radius_top_left = 0.0f;
    float radius_top_right = 0.0f;
    float radius_bottom_left = 0.0f;
    float radius_bottom_right = 0.0f;
    bool clip_horizontal = false;
    bool clip_vertical = false;
    bool visible = true;
    LayoutTransform transform{};
    float transform_origin_x = 0.5f;
    float transform_origin_y = 0.5f;
};

/**
 * Where the framework laid one node out (ADR 0009): its bounds in layout coordinates, where its text goes relative to
 * them, its first baseline in layout coordinates when it has one, and the scroll offset of a scroll container's content.
 */
struct LayoutPlacement {
    bool operator==(const LayoutPlacement &) const = default;
    LayoutRect bounds{};
    float text_x = 0.0f;
    float text_y = 0.0f;
    float text_width = 0.0f;
    float baseline = 0.0f;
    bool has_baseline = false;
    /** How far a scroll container's content moves left and up, ahead of its own transform. */
    float scroll_x = 0.0f;
    float scroll_y = 0.0f;
    /** Whether layout hid it: it is neither drawn nor hit. */
    bool hidden = false;
};

/** A flat, frame-scoped render/layout tree. Parent indices refer to this array. */
struct LayoutNode {
    bool operator==(const LayoutNode &) const = default;
    uint32_t id = 0;
    int32_t parent = -1;
    LayoutVisualKind visual_kind = LayoutVisualKind::Box;
    LayoutStyle style{};
    std::string text;
    LayoutColor text_color{1.0f, 1.0f, 1.0f, 1.0f};
    TextStyle text_style{};
    ParagraphStyle paragraph_style{};
    /** Geometric hit policy supplied by the framework layer. */
    bool hit_self = true;
    bool hit_children = true;
    /** Where the framework laid it out (ADR 0009). */
    LayoutPlacement placement{};
    /** Paint/text revision supplied by the retained scene owner. */
    uint32_t content_revision = 0;
    /** Resolved bounds/transform/clip revision supplied by the retained scene owner. */
    uint32_t geometry_revision = 0;
    /** Opacity/effects revision supplied by the retained scene owner. */
    uint32_t composite_revision = 0;
};

/** Borrowed ordered nodes and parent indices. Retained sessions keep node storage stable across topology edits. */
class LayoutNodeView {
  public:
    explicit LayoutNodeView(const std::vector<const LayoutNode *> &nodes) : nodes_(nodes) {}
    std::size_t size() const { return nodes_.size(); }
    bool empty() const { return nodes_.empty(); }
    const LayoutNode &operator[](std::size_t index) const { return *nodes_[index]; }
    int32_t parent(std::size_t index) const { return nodes_[index]->parent; }
    struct Iterator {
        const LayoutNodeView *view;
        std::size_t index;
        const LayoutNode &operator*() const { return (*view)[index]; }
        Iterator &operator++() { ++index; return *this; }
        bool operator!=(const Iterator &other) const { return index != other.index; }
    };
    Iterator begin() const { return {this, 0}; }
    Iterator end() const { return {this, size()}; }
  private:
    const std::vector<const LayoutNode *> &nodes_;
};

struct LayoutError {
    std::size_t node_index = 0;
    const char *message = nullptr;
};

constexpr uint32_t kInvalidLayoutIndex = UINT32_MAX;

struct LayoutItem {
    bool operator==(const LayoutItem &) const = default;
    uint32_t id = 0;
    LayoutVisualKind visual_kind = LayoutVisualKind::Box;
    LayoutRect bounds{};
    LayoutRect clip_bounds{};
    LayoutRect content_bounds{};
    LayoutTransform transform{};
    float baseline = 0.0f;
    bool visible = true;
    bool has_baseline = false;
    uint32_t parent_id = 0;
    /** Submission-order index of this item. */
    uint32_t index = kInvalidLayoutIndex;
    /** Parent index in LayoutSnapshot::items, or kInvalidLayoutIndex for the root. */
    uint32_t parent_index = kInvalidLayoutIndex;
    /** Range into LayoutSnapshot::child_indices for direct children. */
    uint32_t child_offset = 0;
    uint32_t child_count = 0;
    /** Node-local bounds, always rooted at (0, 0). */
    LayoutRect local_bounds{};
    /** Axis-aligned viewport bounds after the cumulative transform. */
    LayoutRect world_bounds{};
    /** Viewport bounds covering all hittable content below this item. */
    LayoutRect subtree_hit_bounds{};
    /** Inverse of transform, mapping viewport coordinates to layout coordinates. */
    LayoutTransform inverse_transform{};
    /** Native paint-order key; larger values are painted later. */
    uint64_t paint_order = 0;
    int32_t z_index = 0;
    bool positioned_absolute = false;
    bool hit_self = true;
    bool hit_children = true;
    uint32_t content_revision = 0;
    uint32_t geometry_revision = 0;
    uint32_t composite_revision = 0;
};

enum class LayoutPrimitiveKind : uint8_t {
    Rectangle = 1,
    Border,
    Text,
    ClipBegin,
    ClipEnd,
    Custom,
};

struct LayoutPrimitive {
    bool operator==(const LayoutPrimitive &) const = default;
    LayoutPrimitiveKind kind = LayoutPrimitiveKind::Rectangle;
    uint32_t node_id = 0;
    LayoutRect bounds{};
    LayoutTransform transform{};
    bool visible = true;
    LayoutColor color{};
    float radius_top_left = 0.0f;
    float radius_top_right = 0.0f;
    float radius_bottom_left = 0.0f;
    float radius_bottom_right = 0.0f;
    std::string text;
    TextStyle text_style{};
    ParagraphStyle paragraph_style{};
    TextLayoutId text_layout_id = 0;
    uint32_t text_line_index = 0;
    uint32_t content_revision = 0;
    uint32_t geometry_revision = 0;
    uint32_t composite_revision = 0;
};

struct LayoutTextLine {
    bool operator==(const LayoutTextLine &) const = default;
    std::size_t text_offset = 0;
    std::size_t text_length = 0;
    LayoutRect bounds{};
};

struct LayoutTextLayout {
    bool operator==(const LayoutTextLayout &) const = default;
    TextLayoutId id = 0;
    uint32_t node_id = 0;
    std::string text;
    float width = 0.0f;
    float height = 0.0f;
    float first_line_baseline = 0.0f;
    bool has_baseline = false;
    TextStyle text_style{};
    ParagraphStyle paragraph_style{};
    std::vector<LayoutTextLine> lines;
};

struct LayoutSnapshot {
    bool operator==(const LayoutSnapshot &) const = default;
    std::vector<LayoutItem> items;
    std::vector<uint32_t> child_indices;
    std::vector<LayoutPrimitive> primitives;
    std::vector<LayoutTextLayout> text_layouts;

    const LayoutItem *find(uint32_t id) const {
        const auto found = std::find_if(items.begin(), items.end(),
                                        [id](const LayoutItem &item) { return item.id == id; });
        return found == items.end() ? nullptr : &*found;
    }
};

} // namespace nkui

#endif
