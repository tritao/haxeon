#include "layout/layout_engine.h"
#include "layout/layout_cost.h"
#include "layout/layout_id_index.h"

#include "prepare/text_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>

namespace nkui {
namespace {

constexpr std::size_t kAutomaticTextLayoutCacheEntries = 128;

TextLayoutOptions text_options_for_node(const LayoutNode &node) {
    TextLayoutOptions options;
    options.font_size = node.text_style.font_size;
    options.letter_spacing = node.text_style.letter_spacing;
    options.line_height = node.paragraph_style.line_height;
    options.tab_width = node.paragraph_style.tab_width;
    options.family = node.text_style.family;
    options.wrap = node.paragraph_style.wrap;
    options.alignment = node.paragraph_style.alignment;
    options.direction = node.paragraph_style.direction;
    return options;
}

LayoutTransform compose(LayoutTransform parent, LayoutTransform local) {
    return {parent.a * local.a + parent.c * local.b,
            parent.b * local.a + parent.d * local.b,
            parent.a * local.c + parent.c * local.d,
            parent.b * local.c + parent.d * local.d,
            parent.a * local.tx + parent.c * local.ty + parent.tx,
            parent.b * local.tx + parent.d * local.ty + parent.ty};
}

LayoutTransform translated(float x, float y) {
    return {1.0f, 0.0f, 0.0f, 1.0f, x, y};
}

bool finite_transform(const LayoutTransform &transform) {
    return std::isfinite(transform.a) && std::isfinite(transform.b) && std::isfinite(transform.c) &&
           std::isfinite(transform.d) && std::isfinite(transform.tx) && std::isfinite(transform.ty);
}

bool axis_aligned(const LayoutTransform &transform) {
    return std::abs(transform.b) <= 0.00001f && std::abs(transform.c) <= 0.00001f;
}

LayoutRect transform_bounds(LayoutRect rect, LayoutTransform transform) {
    const auto x = [&](float px, float py) {
        return transform.a * px + transform.c * py + transform.tx;
    };
    const auto y = [&](float px, float py) {
        return transform.b * px + transform.d * py + transform.ty;
    };
    const float x0 = x(rect.x, rect.y);
    const float x1 = x(rect.x + rect.width, rect.y);
    const float x2 = x(rect.x, rect.y + rect.height);
    const float x3 = x(rect.x + rect.width, rect.y + rect.height);
    const float y0 = y(rect.x, rect.y);
    const float y1 = y(rect.x + rect.width, rect.y);
    const float y2 = y(rect.x, rect.y + rect.height);
    const float y3 = y(rect.x + rect.width, rect.y + rect.height);
    const float left = std::min({x0, x1, x2, x3});
    const float top = std::min({y0, y1, y2, y3});
    return {left, top, std::max({x0, x1, x2, x3}) - left, std::max({y0, y1, y2, y3}) - top};
}

bool inverse_transform(LayoutTransform transform, LayoutTransform &out) {
    const float determinant = transform.a * transform.d - transform.b * transform.c;
    if (!finite_transform(transform) || !std::isfinite(determinant) ||
        std::abs(determinant) < 0.000001f)
        return false;
    const float reciprocal = 1.0f / determinant;
    out = {transform.d * reciprocal,
           -transform.b * reciprocal,
           -transform.c * reciprocal,
           transform.a * reciprocal,
           (transform.c * transform.ty - transform.d * transform.tx) * reciprocal,
           (transform.b * transform.tx - transform.a * transform.ty) * reciprocal};
    return finite_transform(out);
}

/** A node's own transform about its transform origin, from its layout bounds. */
LayoutTransform local_transform(const LayoutNode &node, LayoutRect bounds) {
    const float origin_x = bounds.x + bounds.width * node.style.transform_origin_x;
    const float origin_y = bounds.y + bounds.height * node.style.transform_origin_y;
    return compose(compose(translated(origin_x, origin_y), node.style.transform), translated(-origin_x, -origin_y));
}

/**
 * The start of a box of `size` placed on the cross axis of an anchor from `start` over `extent`: the anchor's `align`
 * fraction meets the box's `box_align` fraction.
 */
float cross_start(float start, float extent, float size, float align, float box_align) {
    return start + extent * align - size * box_align;
}

LayoutRect intersect_axes(LayoutRect clip, LayoutRect bounds, bool horizontal, bool vertical) {
    if (horizontal) {
        const float right = std::min(clip.x + clip.width, bounds.x + bounds.width);
        clip.x = std::max(clip.x, bounds.x);
        clip.width = std::max(0.0f, right - clip.x);
    }
    if (vertical) {
        const float bottom = std::min(clip.y + clip.height, bounds.y + bounds.height);
        clip.y = std::max(clip.y, bounds.y);
        clip.height = std::max(0.0f, bottom - clip.y);
    }
    return clip;
}

LayoutRect intersect_rect(LayoutRect left, LayoutRect right) {
    return {std::max(left.x, right.x), std::max(left.y, right.y),
            std::max(0.0f, std::min(left.x + left.width, right.x + right.width) -
                               std::max(left.x, right.x)),
            std::max(0.0f, std::min(left.y + left.height, right.y + right.height) -
                               std::max(left.y, right.y))};
}

bool has_area(LayoutRect rect) {
    return rect.width > 0.0f && rect.height > 0.0f;
}

LayoutRect union_rect(LayoutRect left, LayoutRect right) {
    if (!has_area(left))
        return right;
    if (!has_area(right))
        return left;
    const float x = std::min(left.x, right.x);
    const float y = std::min(left.y, right.y);
    const float right_edge = std::max(left.x + left.width, right.x + right.width);
    const float bottom_edge = std::max(left.y + left.height, right.y + right.height);
    return {x, y, right_edge - x, bottom_edge - y};
}

bool finite_rect(LayoutRect rect) {
    return std::isfinite(rect.x) && std::isfinite(rect.y) && std::isfinite(rect.width) &&
           std::isfinite(rect.height) && rect.width >= 0.0f && rect.height >= 0.0f;
}

} // namespace

struct LayoutEngine::Impl {
    explicit Impl(std::shared_ptr<FontCollection> fonts = {})
        : text(fonts ? std::move(fonts) : std::make_shared<FontCollection>()) {}

    bool valid() const { return text.valid(); }
    bool layout(const LayoutNodeView &nodes, const std::vector<LayoutPlacement> &placements, float width,
                float height, LayoutSnapshot &out, LayoutError *error, const LayoutInputChanges *changes);
    bool shape_text(const LayoutNode &node, const LayoutPlacement &placement, LayoutSnapshot &out);
    void emit(const LayoutNodeView &nodes, std::size_t index, LayoutSnapshot &out);

    TextEngine text;
    std::vector<const LayoutNode *> dense_nodes;
    std::vector<std::vector<std::size_t>> children;
    bool prepared = false;
    std::size_t root_index = 0;
    std::vector<std::vector<std::size_t>> floating_children;
    std::vector<std::vector<std::size_t>> overlay_children;
    std::vector<std::size_t> context_order;
    std::vector<int32_t> layers;
    LayoutIdIndex placement_index;
    std::vector<const LayoutPlacement *> node_placements;
    std::vector<std::size_t> node_text_layouts;
    std::vector<TextLayoutId> retained_text_layouts;
};

bool LayoutEngine::Impl::layout(const LayoutNodeView &nodes, const std::vector<LayoutPlacement> &placements,
                                float width, float height, LayoutSnapshot &out, LayoutError *error,
                                const LayoutInputChanges *changes) {
    if (error)
        *error = {};
    out = {};
    if (!valid() || nodes.empty() || !std::isfinite(width) || !std::isfinite(height) || width <= 0.0f ||
        height <= 0.0f) {
        if (error)
            error->message = "invalid layout input";
        return false;
    }

    const double prepare_started = layout_cost_time();
    auto &state = *this;
    const bool topology_changed = !state.prepared || !changes || changes->topology;
    const bool layers_changed = topology_changed || changes->layers;
    state.prepared = false;
    std::size_t root = state.root_index;
    if (topology_changed) {
        state.children.assign(nodes.size(), {});

        root = nodes.size();
        std::vector<uint8_t> marks(nodes.size(), 0);
        std::unordered_map<uint32_t, std::size_t> ids;
        for (std::size_t index = 0; index < nodes.size(); ++index) {
            const auto &node = nodes[index];
            if ((!changes || !changes->topology_validated) && (!node.id || !ids.emplace(node.id, index).second)) {
                if (error) {
                    error->node_index = index;
                    error->message = "layout node IDs must be unique and non-zero";
                }
                return false;
            }
            if (node.style.overlay && node.style.positioning != LayoutPositioning::Absolute) {
                if (error) {
                    error->node_index = index;
                    error->message = "layout overlays require absolute positioning";
                }
                return false;
            }
            if (node.parent < 0) {
                if (root != nodes.size()) {
                    if (error) {
                        error->node_index = index;
                        error->message = "layout tree must have exactly one root";
                    }
                    return false;
                }
                root = index;
            } else if (static_cast<std::size_t>(node.parent) >= nodes.size()) {
                if (error) {
                    error->node_index = index;
                    error->message = "layout node parent is out of range";
                }
                return false;
            } else {
                state.children[static_cast<std::size_t>(node.parent)].push_back(index);
            }
        }
        if (root == nodes.size()) {
            if (error)
                error->message = "layout tree must have exactly one root";
            return false;
        }

        const auto visit = [&](auto &&self, std::size_t index) -> bool {
            if (marks[index] == 1)
                return false;
            if (marks[index] == 2)
                return true;
            marks[index] = 1;
            for (const std::size_t child : state.children[index]) {
                if (!self(self, child))
                    return false;
            }
            marks[index] = 2;
            return true;
        };
        if ((!changes || !changes->topology_validated) && (!visit(visit, root) ||
            std::any_of(marks.begin(), marks.end(), [](uint8_t mark) { return mark != 2; }))) {
            if (error)
                error->message = "layout tree contains a cycle or disconnected node";
            return false;
        }

        state.root_index = root;
    }

    auto &floating_children = state.floating_children;
    auto &overlay_children = state.overlay_children;
    auto &context_order = state.context_order;
    auto &layers = state.layers;
    if (layers_changed) {
        // Ordinary floating contexts preserve nested z-order. Overlays escape those
        // contexts, but remain inside the nearest enclosing overlay (e.g. a dialog).
        floating_children.assign(nodes.size(), {});
        overlay_children.assign(nodes.size(), {});
        const auto collect_floating = [&](auto &&self, std::size_t index,
                                          std::size_t owner, std::size_t overlay_owner) -> void {
            if (index != root && nodes[index].style.positioning == LayoutPositioning::Absolute) {
                if (nodes[index].style.overlay) {
                    overlay_children[overlay_owner].push_back(index);
                    overlay_owner = index;
                } else {
                    floating_children[owner].push_back(index);
                }
                owner = index;
            }
            for (const std::size_t child : state.children[index])
                self(self, child, owner, overlay_owner);
        };
        collect_floating(collect_floating, root, root, root);
        context_order.clear();
        const auto order_floating = [&](auto &&self, std::size_t owner) -> void {
            const auto sort_children = [&](auto &children) {
                std::stable_sort(children.begin(), children.end(), [&](std::size_t left,
                                                                       std::size_t right) {
                    return nodes[left].style.z_index < nodes[right].style.z_index;
                });
            };
            auto &children = floating_children[owner];
            sort_children(children);
            for (const std::size_t child : children)
                if (nodes[child].style.z_index < 0) self(self, child);
            context_order.push_back(owner);
            for (const std::size_t child : children)
                if (nodes[child].style.z_index >= 0) self(self, child);
            auto &overlays = overlay_children[owner];
            sort_children(overlays);
            for (const std::size_t child : overlays) self(self, child);
        };
        order_floating(order_floating, root);
        const auto root_order = std::find(context_order.begin(), context_order.end(), root);
        layers.assign(nodes.size(), 0);
        for (std::size_t order = 0; order < context_order.size(); ++order) {
            const auto rank = static_cast<int64_t>(order) - (root_order - context_order.begin());
            if (rank < std::numeric_limits<int16_t>::min() ||
                rank > std::numeric_limits<int16_t>::max()) {
                if (error)
                    error->message = "layout has too many floating layers";
                return false;
            }
            layers[context_order[order]] = static_cast<int32_t>(rank);
        }
        const auto assign_layers = [&](auto &&self, std::size_t index,
                                       int32_t owner_layer) -> void {
            if (index != root && nodes[index].style.positioning == LayoutPositioning::Absolute)
                owner_layer = layers[index];
            layers[index] = owner_layer;
            for (const std::size_t child : state.children[index])
                self(self, child, owner_layer);
        };
        assign_layers(assign_layers, root, 0);
    }

    const double placement_started = layout_cost_time();
    placement_index.reset(placements.size());
    for (std::size_t index = 0; index < placements.size(); ++index)
        placement_index.insert(placements[index].node_id, index);
    std::vector<LayoutRect> node_bounds(nodes.size());
    node_placements.assign(nodes.size(), nullptr);
    for (std::size_t index = 0; index < nodes.size(); ++index) {
        const std::size_t found = placement_index.find(nodes[index].id);
        if (found == LayoutIdIndex::missing || !finite_rect(placements[found].bounds) ||
            !std::isfinite(placements[found].text_x) || !std::isfinite(placements[found].text_y) ||
            !std::isfinite(placements[found].text_width)) {
            if (error) {
                error->node_index = index;
                error->message = "a laid-out node needs a finite placement";
            }
            return false;
        }
        node_placements[index] = &placements[found];
        node_bounds[index] = placements[found].bounds;
    }

    // Text is shaped at the width its node gave it; the text engine keeps recent layouts, so unchanged text is not
    // shaped again.
    node_text_layouts.assign(nodes.size(), std::numeric_limits<std::size_t>::max());
    retained_text_layouts.clear();
    for (std::size_t index = 0; index < nodes.size(); ++index) {
        const LayoutNode &node = nodes[index];
        if (node.visual_kind != LayoutVisualKind::Text || node.text.empty() ||
            node_placements[index]->text_width <= 0.0f)
            continue;
        if (!shape_text(node, *node_placements[index], out)) {
            if (error) {
                error->node_index = index;
                error->message = "text could not be shaped at its width";
            }
            return false;
        }
        node_text_layouts[index] = out.text_layouts.size() - 1;
        retained_text_layouts.push_back(out.text_layouts.back().id);
    }
    const double snapshot_started = layout_cost_time();

    out.items.resize(nodes.size());
    out.child_indices.clear();
    out.child_indices.reserve(nodes.size() > 0 ? nodes.size() - 1 : 0);
    const LayoutRect viewport{0.0f, 0.0f, width, height};
    const auto resolve_geometry = [&](auto &&self, std::size_t index,
                                      LayoutTransform parent_transform, bool parent_visible,
                                      LayoutRect parent_clip, LayoutRect parent_bounds) -> bool {
        const auto &node = nodes[index];
        const LayoutTransform transform =
            compose(parent_transform, local_transform(node, node_bounds[index]));
        const bool visible = parent_visible && node.style.visible;
        const LayoutRect transformed = transform_bounds(node_bounds[index], transform);
        LayoutRect item_clip = parent_clip;
        if (node.style.positioning == LayoutPositioning::Absolute) {
            if (node.style.clip_to_parent) {
                const LayoutRect transformed_parent_bounds =
                    transform_bounds(parent_bounds, parent_transform);
                item_clip = intersect_axes(item_clip, transformed_parent_bounds, true, true);
            } else {
                // A floating node escapes its ancestors' clips: custom painters, text, effects and hit geometry with it.
                item_clip = viewport;
            }
        }
        LayoutItem item{};
        item.id = node.id;
        item.parent_id = node.parent >= 0 ? nodes[static_cast<std::size_t>(node.parent)].id : 0;
        item.index = static_cast<uint32_t>(index);
        item.parent_index =
            node.parent >= 0 ? static_cast<uint32_t>(node.parent) : kInvalidLayoutIndex;
        item.child_offset = static_cast<uint32_t>(out.child_indices.size());
        item.child_count = static_cast<uint32_t>(state.children[index].size());
        for (const std::size_t child : state.children[index])
            out.child_indices.push_back(static_cast<uint32_t>(child));
        item.visual_kind = node.visual_kind;
        item.bounds = node_bounds[index];
        item.clip_bounds = item_clip;
        item.transform = transform;
        item.local_bounds = {0.0f, 0.0f, node_bounds[index].width, node_bounds[index].height};
        item.world_bounds = transformed;
        item.z_index = node.style.z_index;
        item.positioned_absolute = node.style.positioning == LayoutPositioning::Absolute;
        item.visible = visible;
        item.hit_self = node.hit_self;
        item.hit_children = node.hit_children;
        item.content_revision = node.content_revision;
        item.geometry_revision = node.geometry_revision;
        item.composite_revision = node.composite_revision;
        const float determinant = transform.a * transform.d - transform.b * transform.c;
        if (!finite_transform(transform) || !std::isfinite(determinant) ||
            std::abs(determinant) < 0.000001f || !std::isfinite(transformed.x) ||
            !std::isfinite(transformed.y) || !std::isfinite(transformed.width) ||
            !std::isfinite(transformed.height)) {
            if (error) {
                error->node_index = index;
                error->message = "layout transform is not finite and invertible";
            }
            return false;
        }
        if (!inverse_transform(transform, item.inverse_transform)) {
            if (error) {
                error->node_index = index;
                error->message = "layout transform inverse could not be resolved";
            }
            return false;
        }
        if (!axis_aligned(transform)) {
            if (node.style.clip_horizontal || node.style.clip_vertical) {
                if (error) {
                    error->node_index = index;
                    error->message = "rotated or skewed clipping is not supported";
                }
                return false;
            }
        }
        const float content_x = node_bounds[index].x + node.style.padding_left;
        const float content_y = node_bounds[index].y + node.style.padding_top;
        bool has_child = false;
        float left = 0.0f;
        float top = 0.0f;
        float right = 0.0f;
        float bottom = 0.0f;
        for (const std::size_t child : state.children[index]) {
            const LayoutRect bounds = node_bounds[child];
            const float child_left = bounds.x - content_x;
            const float child_top = bounds.y - content_y;
            if (!has_child) {
                left = child_left;
                top = child_top;
                right = child_left + bounds.width;
                bottom = child_top + bounds.height;
                has_child = true;
            } else {
                left = std::min(left, child_left);
                top = std::min(top, child_top);
                right = std::max(right, child_left + bounds.width);
                bottom = std::max(bottom, child_top + bounds.height);
            }
        }
        if (has_child)
            item.content_bounds = {left, top, right - left, bottom - top};
        if (node_placements[index]->has_baseline && std::isfinite(node_placements[index]->baseline)) {
            item.has_baseline = true;
            item.baseline = node_placements[index]->baseline;
        }
        out.items[index] = item;

        LayoutRect child_clip = item_clip;
        if (node.style.clip_horizontal || node.style.clip_vertical) {
            child_clip = intersect_axes(child_clip, transformed, node.style.clip_horizontal,
                                        node.style.clip_vertical);
        }
        for (const std::size_t child : state.children[index]) {
            if (!self(self, child, transform, visible, child_clip, node_bounds[index]))
                return false;
        }
        LayoutRect subtree = item.hit_self && item.visible
                                 ? intersect_rect(item.world_bounds, item.clip_bounds)
                                 : LayoutRect{};
        if (item.hit_children && item.visible) {
            for (const std::size_t child : state.children[index])
                subtree = union_rect(subtree, out.items[child].subtree_hit_bounds);
        }
        item.subtree_hit_bounds = subtree;
        out.items[index] = item;
        return true;
    };
    if (!resolve_geometry(resolve_geometry, root, LayoutTransform{}, true, viewport, viewport))
        return false;

    text.prune_layout_cache(retained_text_layouts, kAutomaticTextLayoutCacheEntries);

    // Paint primitives, one stacking context after another in paint order: each context's own subtree in tree order,
    // with an absolute node's subtree painted in its own context instead.
    for (const std::size_t owner : context_order) {
        const LayoutNode &node = nodes[owner];
        const bool clipped_to_parent = owner != root && node.style.positioning == LayoutPositioning::Absolute &&
                                       node.style.clip_to_parent;
        if (clipped_to_parent) {
            LayoutPrimitive clip{};
            clip.kind = LayoutPrimitiveKind::ClipBegin;
            clip.node_id = node.id;
            clip.bounds = out.items[owner].clip_bounds;
            clip.visible = out.items[owner].visible;
            out.primitives.push_back(std::move(clip));
        }
        emit(nodes, owner, out);
        if (clipped_to_parent) {
            LayoutPrimitive end{};
            end.kind = LayoutPrimitiveKind::ClipEnd;
            end.node_id = node.id;
            out.primitives.push_back(std::move(end));
        }
    }

    // Publish one native paint-order key for every resolved node. A node's
    // absolute-positioned ancestor is its stacking owner: the entire owned
    // subtree compares as one layer against ordinary flow content, while
    // declaration/DFS order remains stable within an equal layer. This is
    // the same ordering used by geometric picking and by the primitives above.
    struct PaintOrderKey {
        int32_t layer_z = 0;
        bool floating = false;
        uint64_t owner_order = 0;
        uint64_t traversal_order = 0;
    };
    std::vector<PaintOrderKey> paint_keys(out.items.size());
    uint64_t traversal_order = 0;
    const auto collect_paint_order = [&](auto &&self, std::size_t index, int32_t layer_z,
                                         bool floating, uint64_t owner_order) -> void {
        const auto &node = nodes[index];
        const uint64_t node_order = traversal_order++;
        if (node.style.positioning == LayoutPositioning::Absolute) {
            layer_z = layers[index];
            floating = true;
            owner_order = node_order;
        }
        paint_keys[index] = {layer_z, floating, owner_order, node_order};
        for (const std::size_t child : state.children[index])
            self(self, child, layer_z, floating, owner_order);
    };
    collect_paint_order(collect_paint_order, root, 0, false, 0);

    std::vector<std::size_t> paint_indices(out.items.size());
    for (std::size_t index = 0; index < paint_indices.size(); ++index)
        paint_indices[index] = index;
    std::stable_sort(paint_indices.begin(), paint_indices.end(),
                     [&](std::size_t left, std::size_t right) {
                         const auto &left_key = paint_keys[left];
                         const auto &right_key = paint_keys[right];
                         if (left_key.layer_z != right_key.layer_z)
                             return left_key.layer_z < right_key.layer_z;
                         if (left_key.floating != right_key.floating)
                             return !left_key.floating;
                         if (left_key.owner_order != right_key.owner_order)
                             return left_key.owner_order < right_key.owner_order;
                         return left_key.traversal_order < right_key.traversal_order;
                     });
    for (std::size_t order = 0; order < paint_indices.size(); ++order)
        out.items[paint_indices[order]].paint_order = order + 1;

    const double snapshot_finished = layout_cost_time();
    state.prepared = true;
    if (layout_cost_enabled())
        std::fprintf(stderr, "layout-cost backend nodes=%zu prepare=%.9f solve=%.9f snapshot=%.9f\n",
                     nodes.size(), placement_started - prepare_started, snapshot_started - placement_started,
                     snapshot_finished - snapshot_started);
    return true;
}

bool LayoutEngine::Impl::shape_text(const LayoutNode &node, const LayoutPlacement &placement, LayoutSnapshot &out) {
    const TextLayoutOptions options = text_options_for_node(node);
    TextLayoutResult shaped;
    if (!text.layout_utf8(node.text.c_str(), placement.text_width, options, &shaped) || shaped.id == 0)
        return false;
    LayoutTextLayout layout;
    layout.id = shaped.id;
    layout.node_id = node.id;
    layout.text = node.text;
    layout.width = placement.text_width;
    layout.height = shaped.bounds.height;
    const TextCaret first_caret = text.caret({0, 0});
    layout.first_line_baseline = first_caret.y;
    layout.has_baseline = std::isfinite(first_caret.y);
    layout.text_style = node.text_style;
    layout.paragraph_style = node.paragraph_style;
    layout.lines.reserve(shaped.lines.size());
    for (const TextLayoutLine &line : shaped.lines) {
        if (line.text_offset > node.text.size() || line.text_length > node.text.size() - line.text_offset)
            return false;
        layout.lines.push_back(
            {line.text_offset, line.text_length, {line.bounds.x, line.bounds.y, line.bounds.width, line.bounds.height}});
    }
    out.text_layouts.push_back(std::move(layout));
    return true;
}

/**
 * A node's primitives: its clip, its background, its text lines, its custom content, then its flow subtree, then the
 * end of its clip. Absolute descendants paint in their own stacking context.
 */
void LayoutEngine::Impl::emit(const LayoutNodeView &nodes, std::size_t index, LayoutSnapshot &out) {
    const LayoutNode &node = nodes[index];
    const LayoutItem &item = out.items[index];
    const LayoutRect bounds = item.bounds;
    const auto primitive = [&](LayoutPrimitiveKind kind) {
        LayoutPrimitive value{};
        value.kind = kind;
        value.node_id = node.id;
        value.bounds = bounds;
        value.transform = item.transform;
        value.visible = item.visible;
        value.content_revision = node.content_revision;
        value.geometry_revision = node.geometry_revision;
        value.composite_revision = node.composite_revision;
        return value;
    };
    const bool clips = node.style.clip_horizontal || node.style.clip_vertical;
    if (clips) {
        LayoutPrimitive clip = primitive(LayoutPrimitiveKind::ClipBegin);
        clip.bounds = intersect_axes(item.clip_bounds, item.world_bounds, node.style.clip_horizontal,
                                     node.style.clip_vertical);
        clip.transform = LayoutTransform{};
        out.primitives.push_back(std::move(clip));
    }
    if (node.style.background.alpha > 0.0f) {
        LayoutPrimitive rectangle = primitive(LayoutPrimitiveKind::Rectangle);
        rectangle.color = node.style.background;
        rectangle.radius_top_left = node.style.radius_top_left;
        rectangle.radius_top_right = node.style.radius_top_right;
        rectangle.radius_bottom_left = node.style.radius_bottom_left;
        rectangle.radius_bottom_right = node.style.radius_bottom_right;
        out.primitives.push_back(std::move(rectangle));
    }
    if (node_text_layouts[index] != std::numeric_limits<std::size_t>::max()) {
        const LayoutTextLayout &layout = out.text_layouts[node_text_layouts[index]];
        const LayoutPlacement &placement = *node_placements[index];
        for (std::size_t line = 0; line < layout.lines.size(); ++line) {
            const LayoutTextLine &shaped = layout.lines[line];
            if (shaped.text_length == 0)
                continue;
            LayoutPrimitive run = primitive(LayoutPrimitiveKind::Text);
            run.bounds = {bounds.x + placement.text_x + shaped.bounds.x, bounds.y + placement.text_y + shaped.bounds.y,
                          shaped.bounds.width, shaped.bounds.height};
            run.color = node.text_color;
            run.text.assign(node.text, shaped.text_offset, shaped.text_length);
            run.text_style = node.text_style;
            run.paragraph_style = node.paragraph_style;
            run.text_layout_id = layout.id;
            run.text_line_index = static_cast<uint32_t>(line);
            out.primitives.push_back(std::move(run));
        }
    }
    if (node.visual_kind == LayoutVisualKind::Custom)
        out.primitives.push_back(primitive(LayoutPrimitiveKind::Custom));
    for (const std::size_t child : children[index])
        if (nodes[child].style.positioning != LayoutPositioning::Absolute)
            emit(nodes, child, out);
    if (clips) {
        LayoutPrimitive end{};
        end.kind = LayoutPrimitiveKind::ClipEnd;
        end.node_id = node.id;
        out.primitives.push_back(std::move(end));
    }
}

LayoutEngine::LayoutEngine(std::size_t) : impl_(std::make_unique<Impl>()) {}

LayoutEngine::LayoutEngine(std::shared_ptr<FontCollection> fonts, std::size_t)
    : impl_(std::make_unique<Impl>(std::move(fonts))) {}

LayoutEngine::~LayoutEngine() = default;

bool LayoutEngine::valid() const {
    return impl_ && impl_->valid();
}

TextEngine *LayoutEngine::text_engine() {
    return impl_ ? &impl_->text : nullptr;
}

const TextEngine *LayoutEngine::text_engine() const {
    return impl_ ? &impl_->text : nullptr;
}

bool LayoutEngine::add_font(const char *path, FontFamily family) {
    return impl_ && impl_->text.add_font(path, family);
}

bool LayoutEngine::add_font_from_data(const char *name, const void *data, std::size_t bytes,
                                      FontFamily family) {
    return impl_ && impl_->text.add_font_from_data(name, data, bytes, family);
}

bool LayoutEngine::add_system_fallbacks() {
    return impl_ && impl_->text.add_system_fallbacks();
}

bool LayoutEngine::layout(const std::vector<LayoutNode> &nodes, const std::vector<LayoutPlacement> &placements,
                          float width, float height, LayoutSnapshot &out, LayoutError *error,
                          const LayoutInputChanges *changes) {
    if (!impl_) {
        if (error)
            error->message = "layout implementation is unavailable";
        return false;
    }
    impl_->dense_nodes.clear();
    for (const auto &node : nodes)
        impl_->dense_nodes.push_back(&node);
    return layout(LayoutNodeView(impl_->dense_nodes), placements, width, height, out, error, changes);
}

bool LayoutEngine::layout(const LayoutNodeView &nodes, const std::vector<LayoutPlacement> &placements, float width,
                          float height, LayoutSnapshot &out, LayoutError *error, const LayoutInputChanges *changes) {
    if (!impl_) {
        if (error)
            error->message = "layout implementation is unavailable";
        return false;
    }
    return impl_->layout(nodes, placements, width, height, out, error, changes);
}

} // namespace nkui
