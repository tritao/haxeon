#pragma once

#include "compositor/render_plan.h"
#include "render/frame_resources.h"

#include <bit>
#include <type_traits>
#include <vector>

namespace nkui {

/** Canonical diagnostic bytes: fields and payloads, never addresses, capacities or padding. */
class RenderPlanBytes {
  public:
    std::vector<uint8_t> bytes;

    template <class... T> void fields(const T &...values) { (write(values), ...); }
    template <class T> requires std::is_integral_v<T> void write(T value) {
        if constexpr (std::is_same_v<T, bool>) bytes.push_back(value ? 1 : 0);
        else {
            using U = std::make_unsigned_t<T>;
            const auto bits = static_cast<U>(value);
            for (std::size_t index = 0; index < sizeof(T); ++index)
                bytes.push_back(static_cast<uint8_t>(bits >> (index * 8)));
        }
    }
    template <class T> requires std::is_enum_v<T> void write(T value) {
        write(static_cast<std::underlying_type_t<T>>(value));
    }
    void write(float value) { write(std::bit_cast<uint32_t>(value)); }
    template <class T, std::size_t N> void write(const std::array<T, N> &values) {
        for (const auto &value : values) write(value);
    }
    template <class T, std::size_t N> void write(const T (&values)[N]) {
        for (const auto &value : values) write(value);
    }
    template <class T> void write(const std::vector<T> &values) {
        write(uint64_t{values.size()});
        for (const auto &value : values) write(value);
    }
    void write(AtlasTextureId value) { write(value.value); }
    void write(ResourceId value) { write(value.value); }
    void write(const RenderTargetDescriptor &v) {
        fields(v.width, v.height, v.logical_width, v.logical_height, v.origin_x, v.origin_y,
               v.format, v.sample_count, v.usage, v.generation);
    }
    void write(const BoxShadowDescriptor &v) {
        fields(v.offset_x, v.offset_y, v.blur_sigma, v.spread, v.radii, v.color);
    }
    void write(const RectBorderDescriptor &v) { fields(v.width, v.color); }
    void write(const EffectDescriptor &v) { fields(v.kind, v.color_matrix); }
    void write(const CustomEffectDescriptor &v) {
        fields(v.registration_id, v.parameter_count, v.pass_count, v.sampling_inputs,
               v.ink_overflow, v.parameters);
    }
    void write(const MaskDescriptor &v) { fields(v.kind, v.image, v.values); }
    void write(const RenderCommand &v) {
        fields(v.kind, v.resource, v.x, v.y, v.width, v.height, v.opacity, v.transform, v.paint,
               v.composite, v.has_scissor, v.scissor_x, v.scissor_y, v.scissor_width, v.scissor_height,
               v.stroke_width, v.line_cap, v.line_join, v.miter_limit, v.custom_payload,
               v.content_generation, v.retained_node_id, v.box_shadow, v.rect_border, v.source_uv_extent);
    }
    void write(const RenderPass &v) {
        fields(v.target, v.target_descriptor, v.load_existing, v.commands, v.kind, v.input_target,
               v.effect, v.custom_effect, v.has_input_rect, v.input_rect, v.backdrop, v.mask, v.cache_key);
    }
    void write(const RenderDependency &v) { fields(v.producer, v.consumer); }
    void write(const RenderPlan &v) { fields(v.passes, v.dependencies, v.isolated_layers, v.bounded_layers); }
    void write(const PreparedColor &v) { fields(v.r, v.g, v.b, v.a); }
    void write(const PreparedGradientStop &v) { fields(v.offset, v.color); }
    void write(const PreparedPaint &v) {
        fields(v.transform, v.extent, v.radius, v.feather, v.inner_color, v.outer_color,
               v.image_token, v.kind, v.gradient_start, v.gradient_end, v.gradient_stop_count, v.gradient_stops);
    }
    void write(const PreparedPathOperation &v) {
        fields(v.kind, v.paint, v.fringe, v.stroke_width, v.fill_rule, v.bounds, v.path_offset,
               v.path_count, v.vertex_offset, v.vertex_count);
    }
    void write(const PreparedPathRange &v) {
        fields(v.fill_offset, v.fill_count, v.stroke_offset, v.stroke_count, v.closed, v.convex, v.winding);
    }
    void write(const PreparedVertex &v) { fields(v.x, v.y, v.u, v.v); }
    void write(const PreparedTexture &v) {
        fields(v.token, v.type, v.width, v.height, v.flags, v.generation, v.dirty, v.pixels);
    }
    void write(const PreparedPathData &v) { fields(v.operations(), v.paths(), v.vertices(), v.textures()); }
    void write(const GlyphVertex &v) { fields(v.x, v.y, v.u, v.v, v.red, v.green, v.blue, v.alpha); }
    void write(const GlyphBatch &v) {
        fields(v.atlas, v.atlas_generation, v.mode, v.first_vertex, v.vertex_count, v.first_index, v.index_count);
    }
    void write(const GlyphSourceRange &v) { fields(v.first_vertex, v.vertex_count, v.start, v.end); }
    void write(const PreparedGlyphs &v) {
        fields(v.vertices, v.indices, v.batches, v.source_ranges, v.origin_x, v.origin_y, v.pixel_scale,
               v.mode, v.layout_id, v.layout_generation, v.grid_revision, v.line_revision, v.publication_key,
               v.source_start, v.first_line, v.end_line);
    }
    void resource(ResourceId id, const FrameResources &resources) {
        fields(id, resources.content_generation(id), resources.source_identity(id));
        const auto *path = resources.path(id);
        write(path != nullptr);
        if (path) fields(path->operation_index, *path->path);
        const auto *image = resources.image(id);
        write(image != nullptr);
        if (image) write(*image->image);
        const auto *text = resources.text(id);
        write(text != nullptr);
        if (text) write(*text);
        const auto *graphics_image = resources.graphics_image(id);
        write(graphics_image != nullptr);
        if (graphics_image) write(graphics_image->id);
    }
    void frame(const RenderPlan &plan, const FrameResources &resources) {
        write(plan);
        for (const auto &pass : plan.passes) {
            resource(pass.mask.image, resources);
            for (const auto &command : pass.commands) {
                resource(command.resource, resources);
                resource(command.paint, resources);
            }
        }
    }
};

} // namespace nkui
