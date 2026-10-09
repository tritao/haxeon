#include "text_engine.h"
#include "text_raster.h"

#include "system_fonts.h"

#include "skribidi/skb_attributes.h"
#include "skribidi/skb_font_collection.h"
#include "skribidi/skb_image_atlas.h"
#include "skribidi/skb_layout.h"
#include "skribidi/skb_rasterizer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

namespace nkui {

struct FontCollection::State {
    skb_font_collection_t *fonts = nullptr;
    std::unordered_set<std::string> system_fonts_loaded;
    std::vector<std::shared_ptr<std::vector<uint8_t>>> font_data;
    uint32_t font_load_count = 0;
};

static std::shared_ptr<const skb_layout_t> own_native_layout(
    skb_layout_t *layout, const std::shared_ptr<FontCollection> &fonts) {
    if (!layout)
        return {};
    // The mutable constructor transfers ownership once; every retained reader
    // thereafter sees a const generation. Fonts outlive its native destruction.
    return std::shared_ptr<skb_layout_t>(layout, [fonts](skb_layout_t *value) {
        skb_layout_destroy(value);
        (void)fonts;
    });
}

struct TextEngine::State {
    struct RetainedLayout {
        // Read-only generations can be retained by indexed pieces without
        // later edits mutating or freeing their native data.
        std::shared_ptr<const skb_layout_t> layout;
        std::string text;
        float width = 0.0f;
        TextLayoutOptions options{};
        uint64_t font_generation = 0;
        uint64_t last_used = 0;
        TextLayoutResult result{};
        std::vector<skb_range_t> line_ranges;
        std::vector<uint64_t> line_revisions;
        std::vector<float> prefix_bottoms;
        std::vector<float> suffix_tops;
    };

    std::shared_ptr<FontCollection> font_collection;
    skb_temp_alloc_t *temporary = nullptr;
    skb_rasterizer_t *rasterizer = nullptr;
    skb_image_atlas_t *atlas = nullptr;
    uint16_t next_texture_slot = 1;
    uint16_t texture_namespace = 1;
    TextLayoutId next_layout_id = 1;
    TextLayoutId active_layout_id = 0;
    uint64_t layout_use_sequence = 0;
    uint64_t line_revision_sequence = 0;
    std::unordered_map<TextLayoutId, std::unique_ptr<RetainedLayout>> layouts;
    // Intrinsic (unwrapped) measurements by text and style. Layout asks for every text node on every frame, and shaping
    // a paragraph to answer is most of the cost of a layout in which nothing changed. Invalidated with the fonts.
    std::unordered_map<std::string, TextIntrinsicMetrics> intrinsic_cache;
    uint64_t intrinsic_cache_generation = 0;
    uint32_t layout_builds = 0;
    uint64_t prepared_batch_count = 0;
    uint64_t layout_cache_hits = 0;
    uint64_t layout_cache_misses = 0;
    uint64_t incremental_ascii_edits = 0;
    uint64_t edit_layout_fallbacks = 0;
    uint32_t last_scale_key = 0;
    uint32_t scale_generation = 0;
    std::unordered_map<uint64_t, std::weak_ptr<const PreparedGlyphs>> published_glyphs;
    // The public buffer API asks for size and contents separately. Retain one
    // bounded query so neither that pair nor repeated paints rewalks the text.
    TextLayoutId selection_layout_id = 0;
    uint64_t selection_layout_generation = 0;
    TextPosition selection_start{}, selection_end{};
    std::vector<TextRect> selection_rectangles;
};

namespace {

// Native layouts own their data. Scratch allocations are valid only for one
// operation, including early returns and nested fallback shaping.
class TextScratchScope {
  public:
    explicit TextScratchScope(skb_temp_alloc_t *allocator)
        : allocator_(allocator), mark_(skb_temp_alloc_save(allocator)) {}
    ~TextScratchScope() { skb_temp_alloc_restore(allocator_, mark_); }
    TextScratchScope(const TextScratchScope &) = delete;
    TextScratchScope &operator=(const TextScratchScope &) = delete;
  private:
    skb_temp_alloc_t *allocator_;
    skb_temp_alloc_mark_t mark_;
};

TextEngine::State::RetainedLayout *find_layout(TextEngine::State &state, TextLayoutId id) {
    const auto found = state.layouts.find(id);
    return found == state.layouts.end() ? nullptr : found->second.get();
}

const TextEngine::State::RetainedLayout *find_layout(const TextEngine::State &state,
                                                     TextLayoutId id) {
    const auto found = state.layouts.find(id);
    return found == state.layouts.end() ? nullptr : found->second.get();
}

TextEngine::State::RetainedLayout *active_layout(TextEngine::State &state) {
    return find_layout(state, state.active_layout_id);
}

const TextEngine::State::RetainedLayout *active_layout(const TextEngine::State &state) {
    return find_layout(state, state.active_layout_id);
}

} // namespace

namespace {

bool system_font_fallback(skb_font_collection_t *font_collection, const char *, uint8_t script,
                          uint8_t font_family, void *context) {
    auto *system_fonts_loaded = static_cast<std::unordered_set<std::string> *>(context);
    const uint32_t script_tag = skb_script_to_iso15924_tag(script);
    const bool emoji = font_family == SKB_FONT_FAMILY_EMOJI;
    if (std::getenv("NKUI_DEBUG_GLYPHS"))
        std::fprintf(stderr, "fallback request %c%c%c%c family=%u\n",
                     static_cast<char>(script_tag >> 24), static_cast<char>(script_tag >> 16),
                     static_cast<char>(script_tag >> 8), static_cast<char>(script_tag),
                     static_cast<unsigned>(font_family));
    bool added = false;
    const auto &fallbacks = system_font_fallbacks();
    for (int pass = 0; pass < 2 && !added; ++pass) {
        for (const auto &font : fallbacks) {
            if (emoji && ((pass == 0) != font.color))
                continue;
            if (font.emoji != emoji ||
                (!emoji && font.script_tag != 0 && font.script_tag != script_tag))
                continue;
            const std::string key =
                std::to_string(static_cast<unsigned>(font_family)) + ":" + font.path;
            if (!system_fonts_loaded->insert(key).second)
                return true;
            if (skb_font_collection_add_font(font_collection, font.path.c_str(), font_family,
                                             nullptr)) {
                added = true;
                if (std::getenv("NKUI_DEBUG_GLYPHS"))
                    std::fprintf(stderr, "fallback font %s color=%u\n", font.path.c_str(),
                                 font.color ? 1u : 0u);
                // Family-only candidates, used by the Windows registry adapter,
                // need to be loaded as a group before font selection is retried.
                if (!emoji && font.script_tag == 0)
                    continue;
                return true;
            }
        }
    }
    return added;
}

skb_rasterize_alpha_mode_t raster_mode(GlyphMode mode) {
    return mode == GlyphMode::Sdf ? SKB_RASTERIZE_ALPHA_SDF : SKB_RASTERIZE_ALPHA_MASK;
}

GlyphMode quad_mode(const skb_quad_t &quad, GlyphMode requested) {
    if (quad.flags & SKB_QUAD_IS_COLOR)
        return GlyphMode::Color;
    if (quad.flags & SKB_QUAD_IS_SDF)
        return GlyphMode::Sdf;
    return requested == GlyphMode::Color ? GlyphMode::Alpha : requested;
}

std::vector<std::size_t> utf8_codepoint_offsets(const char *text) {
    std::vector<std::size_t> offsets;
    if (!text)
        return offsets;
    const auto continuation = [](unsigned char value) { return (value & 0xC0u) == 0x80u; };
    const std::size_t length = std::strlen(text);
    offsets.reserve(length + 1);
    std::size_t index = 0;
    while (index < length) {
        offsets.push_back(index);
        const unsigned char first = static_cast<unsigned char>(text[index]);
        std::size_t sequence_length = 1;
        if (first >= 0xC2u && first <= 0xDFu)
            sequence_length = 2;
        else if (first >= 0xE0u && first <= 0xEFu)
            sequence_length = 3;
        else if (first >= 0xF0u && first <= 0xF4u)
            sequence_length = 4;
        if (sequence_length > 1 &&
            (index + sequence_length > length ||
             !std::all_of(text + index + 1, text + index + sequence_length, [&](char value) {
                 return continuation(static_cast<unsigned char>(value));
             })))
            sequence_length = 1;
        index += sequence_length;
    }
    offsets.push_back(length);
    return offsets;
}

bool utf8_byte_range(const std::string &text, int32_t start, int32_t end,
                     std::size_t &byte_start, std::size_t &byte_end) {
    if (start < 0 || end < start)
        return false;
    const auto continuation = [](unsigned char value) { return (value & 0xC0u) == 0x80u; };
    std::size_t index = 0;
    int32_t offset = 0;
    while (offset <= end) {
        if (offset == start)
            byte_start = index;
        if (offset == end) {
            byte_end = index;
            return true;
        }
        if (index >= text.size())
            return false;
        const unsigned char first = static_cast<unsigned char>(text[index]);
        std::size_t sequence_length = 1;
        if (first >= 0xC2u && first <= 0xDFu)
            sequence_length = 2;
        else if (first >= 0xE0u && first <= 0xEFu)
            sequence_length = 3;
        else if (first >= 0xF0u && first <= 0xF4u)
            sequence_length = 4;
        if (sequence_length > 1 &&
            (index + sequence_length > text.size() ||
             !std::all_of(text.data() + index + 1,
                          text.data() + index + sequence_length,
                          [&](char value) {
                              return continuation(static_cast<unsigned char>(value));
                          })))
            sequence_length = 1;
        index += sequence_length;
        ++offset;
    }
    return false;
}

AtlasTextureFormat atlas_format(skb_image_atlas_texture_format_t format) {
    switch (format) {
    case SKB_IMAGE_ATLAS_FORMAT_R8_SDF:
        return AtlasTextureFormat::R8Sdf;
    case SKB_IMAGE_ATLAS_FORMAT_RGBA8_PREMULTIPLIED:
        return AtlasTextureFormat::Rgba8Premultiplied;
    case SKB_IMAGE_ATLAS_FORMAT_R8_MASK:
    default:
        return AtlasTextureFormat::R8Mask;
    }
}

void append_quad(const skb_quad_t &quad, const skb_image_t &atlas, PreparedGlyphs &output) {
    const float u0 =
        (quad.texture.x + quad.pattern.x * quad.texture.width) / static_cast<float>(atlas.width);
    const float v0 =
        (quad.texture.y + quad.pattern.y * quad.texture.height) / static_cast<float>(atlas.height);
    const float u1 = u0 + quad.pattern.width * quad.texture.width / static_cast<float>(atlas.width);
    const float v1 =
        v0 + quad.pattern.height * quad.texture.height / static_cast<float>(atlas.height);
    const uint32_t base = static_cast<uint32_t>(output.vertices.size());
    const auto vertex = [&quad](float x, float y, float u, float v) {
        return GlyphVertex{x, y, u, v, quad.color.r, quad.color.g, quad.color.b, quad.color.a};
    };
    output.vertices.push_back(vertex(quad.geom.x, quad.geom.y, u0, v0));
    output.vertices.push_back(vertex(quad.geom.x + quad.geom.width, quad.geom.y, u1, v0));
    output.vertices.push_back(
        vertex(quad.geom.x + quad.geom.width, quad.geom.y + quad.geom.height, u1, v1));
    output.vertices.push_back(vertex(quad.geom.x, quad.geom.y + quad.geom.height, u0, v1));
    const uint32_t indices[] = {base, base + 1, base + 2, base, base + 2, base + 3};
    output.indices.insert(output.indices.end(), std::begin(indices), std::end(indices));
}

struct RenderGlyphContext {
    TextEngine::State *state = nullptr;
    skb_font_collection_t *font_collection = nullptr;
    const skb_layout_t *layout = nullptr;
    float origin_x = 0.0f;
    float origin_y = 0.0f;
    float pixel_scale = 1.0f;
    GlyphMode requested_mode = GlyphMode::Alpha;
    PreparedGlyphs *output = nullptr;
    int32_t line_start = -1;
    int32_t line_end = -1;
};

// Hard line breaks participate in layout and editing, never in glyph painting.
bool is_hard_line_break(uint32_t codepoint) {
    return codepoint == 0x0a || codepoint == 0x0d || codepoint == 0x85 ||
           codepoint == 0x2028 || codepoint == 0x2029;
}

bool is_line_break_glyph(const skb_layout_t *layout, const skb_layout_render_glyph_t &glyph) {
    if (glyph.text_range.start < 0 || glyph.text_range.end <= glyph.text_range.start ||
        glyph.text_range.end > skb_layout_get_text_count(layout))
        return false;
    for (int32_t offset = glyph.text_range.start; offset < glyph.text_range.end; ++offset)
        if (!is_hard_line_break(skb_layout_get_text_at(layout, offset)))
            return false;
    return true;
}

bool append_render_glyph(const skb_layout_render_glyph_t *glyph, void *context) {
    auto &render = *static_cast<RenderGlyphContext *>(context);
    if (is_line_break_glyph(render.layout, *glyph))
        return true;
    if (render.line_start >= 0 &&
        (glyph->text_range.end <= render.line_start || glyph->text_range.start >= render.line_end))
        return true;
    if (std::getenv("NKUI_DEBUG_GLYPHS")) {
        const uint32_t script = skb_script_to_iso15924_tag(glyph->script);
        std::fprintf(
            stderr, "glyph %c%c%c%c size=%.1f font=%u gid=%u range=%d..%d cp=%x offset=%.1f,%.1f\n",
            static_cast<char>(script >> 24), static_cast<char>(script >> 16),
            static_cast<char>(script >> 8), static_cast<char>(script), glyph->font_size,
            static_cast<unsigned>(glyph->font_handle), static_cast<unsigned>(glyph->glyph_id),
            glyph->text_range.start, glyph->text_range.end,
            glyph->text_range.start >= 0 &&
                    glyph->text_range.start < skb_layout_get_text_count(render.layout)
                ? skb_layout_get_text_at(render.layout, glyph->text_range.start) : 0u,
            glyph->offset_x, glyph->offset_y);
    }
    const skb_quad_t quad = skb_image_atlas_get_glyph_quad(
        render.state->atlas, render.origin_x + glyph->offset_x, render.origin_y + glyph->offset_y,
        render.pixel_scale, render.font_collection, glyph->font_handle, glyph->glyph_id,
        glyph->font_size, glyph->color, raster_mode(render.requested_mode));
    if (quad.flags & SKB_QUAD_IS_EMPTY)
        return true;

    const GlyphMode actual_mode = quad_mode(quad, render.requested_mode);
    const AtlasTextureId atlas_id{static_cast<uint32_t>(
        skb_image_atlas_get_texture_user_data(render.state->atlas, quad.texture_idx))};
    if (!atlas_id.value)
        return false;
    if (render.output->batches.empty() ||
        render.output->batches.back().atlas.value != atlas_id.value ||
        render.output->batches.back().atlas_generation != quad.texture_generation ||
        render.output->batches.back().mode != actual_mode) {
        render.output->batches.push_back({atlas_id, quad.texture_generation, actual_mode,
                                          static_cast<uint32_t>(render.output->vertices.size()), 0,
                                          static_cast<uint32_t>(render.output->indices.size()), 0});
    }
    const skb_image_t *atlas = skb_image_atlas_get_texture(render.state->atlas, quad.texture_idx);
    if (!atlas)
        return false;
    render.output->source_ranges.push_back({
        static_cast<uint32_t>(render.output->vertices.size()), 4,
        glyph->text_range.start, glyph->text_range.end});
    append_quad(quad, *atlas, *render.output);
    auto &batch = render.output->batches.back();
    batch.vertex_count += 4;
    batch.index_count += 6;
    return true;
}

void atlas_texture_created(skb_image_atlas_t *atlas, uint8_t texture_index, void *context) {
    auto &state = *static_cast<TextEngine::State *>(context);
    const uint32_t id = (uint32_t(1) << 28) | (uint32_t(state.texture_namespace & 0x0FFF) << 16) |
                        state.next_texture_slot++;
    skb_image_atlas_set_texture_user_data(atlas, texture_index, id);
}

} // namespace

bool valid_glyph_color_ranges(const std::vector<GlyphColorRange> &ranges) {
    int32_t previous_end = 0;
    for (const auto &range : ranges) {
        if (range.start < previous_end || range.end <= range.start)
            return false;
        previous_end = range.end;
    }
    return true;
}

void apply_glyph_colors(PreparedGlyphs &glyphs, GlyphTint base,
                        const std::vector<GlyphColorRange> &ranges) {
    const auto paint = [](GlyphVertex &vertex, GlyphTint tint) {
        vertex.red = tint.red;
        vertex.green = tint.green;
        vertex.blue = tint.blue;
        vertex.alpha = tint.alpha;
    };
    for (auto &vertex : glyphs.vertices)
        paint(vertex, base);
    for (const auto &source : glyphs.source_ranges) {
        auto range = std::upper_bound(ranges.begin(), ranges.end(), source.start,
            [](int32_t offset, const GlyphColorRange &candidate) { return offset < candidate.start; });
        if (range == ranges.begin())
            continue;
        --range;
        if (source.start >= range->end)
            continue;
        for (uint32_t index = source.first_vertex;
             index < source.first_vertex + source.vertex_count; ++index)
            paint(glyphs.vertices[index], range->tint);
    }
}

FontCollection::FontCollection() : state_(new State) {
    state_->fonts = skb_font_collection_create();
}

FontCollection::~FontCollection() {
    if (state_->fonts)
        skb_font_collection_destroy(state_->fonts);
    delete state_;
}

bool FontCollection::valid() const {
    return state_ && state_->fonts;
}

bool FontCollection::add_font(const char *path, FontFamily family) {
    const uint8_t skb_family =
        family == FontFamily::Monospace ? SKB_FONT_FAMILY_MONOSPACE :
        family == FontFamily::Emoji ? SKB_FONT_FAMILY_EMOJI : SKB_FONT_FAMILY_DEFAULT;
    if (!path || !skb_font_collection_add_font(state_->fonts, path, skb_family, nullptr))
        return false;
    ++state_->font_load_count;
    return true;
}

bool FontCollection::add_font_from_shared_data(const char *name,
                                               const std::shared_ptr<std::vector<uint8_t>> &data,
                                               FontFamily family) {
    const uint8_t skb_family =
        family == FontFamily::Monospace ? SKB_FONT_FAMILY_MONOSPACE :
        family == FontFamily::Emoji ? SKB_FONT_FAMILY_EMOJI : SKB_FONT_FAMILY_DEFAULT;
    if (!name || !*name || !data || data->empty() || !valid() ||
        !skb_font_collection_add_font_from_data(state_->fonts, name, data->data(), data->size(),
                                                nullptr, nullptr, skb_family, nullptr))
        return false;
    state_->font_data.push_back(data);
    ++state_->font_load_count;
    return true;
}

bool FontCollection::add_system_fallbacks() {
    if (!valid())
        return false;
    skb_font_collection_set_on_font_fallback(state_->fonts, system_font_fallback,
                                             &state_->system_fonts_loaded);
    return true;
}

uint64_t FontCollection::generation() const {
    return valid() ? skb_font_collection_get_generation(state_->fonts) : 0;
}

uint32_t FontCollection::font_load_count() const {
    return state_ ? state_->font_load_count : 0;
}

TextEngine::TextEngine() : TextEngine(std::make_shared<FontCollection>()) {}

TextEngine::TextEngine(std::shared_ptr<FontCollection> fonts) : state_(new State) {
    state_->font_collection = std::move(fonts);
    // Small paragraph engines grow on demand; avoid a half-megabyte floor per chunk.
    state_->temporary = skb_temp_alloc_create(32 * 1024);
    state_->rasterizer = skb_rasterizer_create(nullptr);
    // Most engines shape a small editor chunk. Start compact and let Skribidi
    // expand atlas pages to its normal limits as additional glyphs are needed.
    auto atlas_config = skb_image_atlas_get_default_config();
    atlas_config.init_width = 256;
    atlas_config.init_height = 256;
    atlas_config.expand_size = 256;
    // Whole-point rounding rasterizes e.g. a 14px font at 110% as 16px,
    // then shrinks that bitmap to 15.4px. Keep zoomed alpha glyphs at their
    // device size so the renderer can align texels without resampling.
    atlas_config.glyph_alpha.rounding = kAlphaGlyphSizeStep;
    state_->atlas = skb_image_atlas_create(&atlas_config);
    if (state_->atlas)
        skb_image_atlas_set_create_texture_callback(state_->atlas, atlas_texture_created, state_);
}

TextEngine::~TextEngine() {
    state_->layouts.clear();
    if (state_->atlas)
        skb_image_atlas_destroy(state_->atlas);
    if (state_->rasterizer)
        skb_rasterizer_destroy(state_->rasterizer);
    if (state_->temporary)
        skb_temp_alloc_destroy(state_->temporary);
    delete state_;
}

bool TextEngine::valid() const {
    return state_->font_collection && state_->font_collection->valid() && state_->temporary &&
           state_->rasterizer && state_->atlas;
}

bool TextEngine::set_atlas_namespace(uint16_t value) {
    if (!value || value > 0x0FFF || state_->next_texture_slot != 1)
        return false;
    state_->texture_namespace = value;
    return true;
}

bool TextEngine::add_font(const char *path, FontFamily family) {
    return state_->font_collection->add_font(path, family);
}

bool TextEngine::add_font_from_data(const char *name, const void *data, std::size_t bytes,
                                    FontFamily family) {
    if (!name || !*name || !data || !bytes || !valid())
        return false;
    auto owned = std::make_shared<std::vector<uint8_t>>(static_cast<const uint8_t *>(data),
                                                        static_cast<const uint8_t *>(data) + bytes);
    return add_font_from_shared_data(name, owned, family);
}

bool TextEngine::add_font_from_shared_data(const char *name,
                                           const std::shared_ptr<std::vector<uint8_t>> &data,
                                           FontFamily family) {
    if (!name || !*name || !data || data->empty() || !valid())
        return false;
    return state_->font_collection->add_font_from_shared_data(name, data, family);
}

bool TextEngine::add_system_fallbacks() {
    if (!valid())
        return false;
    return state_->font_collection->add_system_fallbacks();
}

bool TextEngine::measure_intrinsic_utf8(const char *text, const TextLayoutOptions &options,
                                        TextIntrinsicMetrics *result) {
    if (!valid() || !text || !std::isfinite(options.font_size) || options.font_size <= 0.0f ||
        !std::isfinite(options.letter_spacing) || !std::isfinite(options.line_height) ||
        options.line_height < 0.0f)
        return false;

    float tab_increment = 0.0f;
    if (options.tab_width > 0) {
        auto space_options = options;
        space_options.tab_width = 0;
        TextIntrinsicMetrics space;
        if (!measure_intrinsic_utf8(" ", space_options, &space)) return false;
        tab_increment = space.advance_x * options.tab_width;
        if (!std::isfinite(tab_increment) || tab_increment <= 0.0f) return false;
    }
    TextScratchScope scratch(state_->temporary);
    constexpr std::size_t max_cached_measurements = 8192;
    const uint64_t font_generation = state_->font_collection->generation();
    if (state_->intrinsic_cache_generation != font_generation) {
        state_->intrinsic_cache.clear();
        state_->intrinsic_cache_generation = font_generation;
    }
    std::string cache_key(text);
    cache_key.push_back('\0');
    const float key_floats[] = {options.font_size, options.letter_spacing, options.line_height};
    cache_key.append(reinterpret_cast<const char *>(key_floats), sizeof(key_floats));
    cache_key.append(reinterpret_cast<const char *>(&options.tab_width), sizeof(options.tab_width));
    const uint32_t key_family = static_cast<uint32_t>(options.family);
    cache_key.append(reinterpret_cast<const char *>(&key_family), sizeof(key_family));
    if (const auto cached = state_->intrinsic_cache.find(cache_key);
        cached != state_->intrinsic_cache.end()) {
        if (result)
            *result = cached->second;
        return true;
    }

    const skb_attribute_t attributes[] = {
        skb_attribute_make_font_size(options.font_size),
        skb_attribute_make_font_family(static_cast<uint8_t>(options.family)),
        skb_attribute_make_letter_spacing(options.letter_spacing),
        skb_attribute_make_line_height(options.line_height > 0.0f ? SKB_LINE_HEIGHT_ABSOLUTE
                                                                  : SKB_LINE_HEIGHT_NORMAL,
                                       options.line_height),
        skb_attribute_make_paint_color(SKB_PAINT_TEXT, SKB_PAINT_STATE_DEFAULT,
                                       skb_rgba(255, 255, 255, 255))};
    const skb_attribute_t layout_attributes[] = {
        skb_attribute_make_text_wrap(SKB_WRAP_NONE),
        skb_attribute_make_horizontal_align(SKB_ALIGN_START),
        skb_attribute_make_tab_stop_increment(tab_increment)};
    const skb_layout_params_t params = {.font_collection = state_->font_collection->state_->fonts,
                                        .layout_width = 1000000.0f,
                                        .layout_attributes =
                                            SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(layout_attributes)};
    skb_layout_t *layout = skb_layout_create(&params);
    if (!layout)
        return false;
    skb_layout_set_utf8(layout, state_->temporary, &params, text, -1,
                        SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(attributes));
    const skb_rect2_t bounds = skb_layout_get_bounds(layout);
    const int32_t line_count = skb_layout_get_lines_count(layout);
    const float native_baseline = line_count > 0 ? skb_layout_get_line_at(layout, 0).baseline : 0.0f;
    const bool has_baseline = line_count > 0 && std::isfinite(native_baseline);
    const float baseline = has_baseline ? native_baseline - bounds.y : 0.0f;
    const float advance_x = skb_layout_get_caret_info_at(layout,
        {skb_layout_get_text_count(layout), SKB_AFFINITY_NONE}).x;
    skb_layout_destroy(layout);
    const TextIntrinsicMetrics metrics{{bounds.x, bounds.y, bounds.width, bounds.height}, advance_x, baseline,
                                       has_baseline};
    if (state_->intrinsic_cache.size() >= max_cached_measurements)
        state_->intrinsic_cache.clear();
    state_->intrinsic_cache.emplace(std::move(cache_key), metrics);
    if (result)
        *result = metrics;
    return true;
}

bool TextEngine::layout_utf8(const char *text, float width, float font_size) {
    TextLayoutOptions options;
    options.font_size = font_size;
    return layout_utf8(text, width, options);
}

bool TextEngine::layout_utf8(const char *text, float width, const TextLayoutOptions &options) {
    return layout_utf8(text, width, options, nullptr);
}

bool TextEngine::layout_utf8(const char *text, float width, const TextLayoutOptions &options,
                             TextLayoutResult *result) {
    if (!valid() || !text || !std::isfinite(width) || width <= 0.0f ||
        !std::isfinite(options.font_size) || options.font_size <= 0.0f ||
        !std::isfinite(options.letter_spacing) || !std::isfinite(options.line_height) ||
        options.line_height < 0.0f)
        return false;
    float tab_increment = 0.0f;
    if (options.tab_width > 0) {
        auto space_options = options;
        space_options.tab_width = 0;
        TextIntrinsicMetrics space;
        if (!measure_intrinsic_utf8(" ", space_options, &space)) return false;
        tab_increment = space.advance_x * options.tab_width;
        if (!std::isfinite(tab_increment) || tab_increment <= 0.0f) return false;
    }
    TextScratchScope scratch(state_->temporary);
    const uint64_t font_generation = state_->font_collection->generation();
    for (auto &entry : state_->layouts) {
        auto &cached = *entry.second;
        if (cached.font_generation == font_generation && cached.text == text &&
            cached.width == width && cached.options.font_size == options.font_size &&
            cached.options.letter_spacing == options.letter_spacing &&
            cached.options.line_height == options.line_height &&
            cached.options.tab_width == options.tab_width &&
            cached.options.family == options.family && cached.options.wrap == options.wrap &&
            cached.options.alignment == options.alignment &&
            cached.options.direction == options.direction) {
            cached.last_used = ++state_->layout_use_sequence;
            state_->active_layout_id = entry.first;
            if (result)
                *result = cached.result;
            ++state_->layout_cache_hits;
            return true;
        }
    }
    ++state_->layout_cache_misses;
    const skb_text_wrap_t wrap = options.wrap == TextWrapMode::None   ? SKB_WRAP_NONE
                                 : options.wrap == TextWrapMode::Word ? SKB_WRAP_WORD
                                                                      : SKB_WRAP_WORD_CHAR;
    const skb_align_t align = options.alignment == TextAlignment::Center ? SKB_ALIGN_CENTER
                              : options.alignment == TextAlignment::End  ? SKB_ALIGN_END
                                                                         : SKB_ALIGN_START;
    const skb_line_height_t line_height_type =
        options.line_height > 0.0f ? SKB_LINE_HEIGHT_ABSOLUTE : SKB_LINE_HEIGHT_NORMAL;
    const skb_text_direction_t base_direction =
        options.direction == TextDirection::Ltr   ? SKB_DIRECTION_LTR
        : options.direction == TextDirection::Rtl ? SKB_DIRECTION_RTL
                                                  : SKB_DIRECTION_AUTO;
    const skb_attribute_t attributes[] = {
        skb_attribute_make_font_size(options.font_size),
        skb_attribute_make_font_family(static_cast<uint8_t>(options.family)),
        skb_attribute_make_letter_spacing(options.letter_spacing),
        skb_attribute_make_line_height(line_height_type, options.line_height),
        skb_attribute_make_paint_color(SKB_PAINT_TEXT, SKB_PAINT_STATE_DEFAULT,
                                       skb_rgba(255, 255, 255, 255))};
    const skb_attribute_t layout_attributes[] = {
        skb_attribute_make_text_wrap(wrap), skb_attribute_make_horizontal_align(align),
        skb_attribute_make_text_base_direction(base_direction),
        skb_attribute_make_tab_stop_increment(tab_increment)};
    const skb_layout_params_t params = {.font_collection = state_->font_collection->state_->fonts,
                                        .layout_width = width,
                                        .layout_attributes =
                                            SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(layout_attributes)};
    auto retained = std::make_unique<State::RetainedLayout>();
    retained->layout = own_native_layout(
        skb_layout_create_utf8(state_->temporary, &params, text, -1,
                               SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(attributes)),
        state_->font_collection);
    if (!retained->layout)
        return false;
    retained->text = text;
    retained->width = width;
    retained->options = options;
    retained->font_generation = font_generation;
    retained->last_used = ++state_->layout_use_sequence;
    TextLayoutResult layout_result;
    layout_result.id = state_->next_layout_id++;
    if (!layout_result.id)
        layout_result.id = state_->next_layout_id++;
    const TextLayoutId layout_id = layout_result.id;
    const skb_rect2_t layout_bounds = skb_layout_get_bounds(retained->layout.get());
    layout_result.bounds = {layout_bounds.x, layout_bounds.y, layout_bounds.width,
                            layout_bounds.height};
    const auto offsets = utf8_codepoint_offsets(text);
    const int32_t lines_count = skb_layout_get_lines_count(retained->layout.get());
    layout_result.lines.reserve(static_cast<std::size_t>(std::max(lines_count, 0)));
    retained->line_ranges.reserve(static_cast<std::size_t>(std::max(lines_count, 0)));
    const int32_t text_count = skb_layout_get_text_count(retained->layout.get());
    for (int32_t index = 0; index < lines_count; ++index) {
        const auto line = skb_layout_get_line_at(retained->layout.get(), index);
        if (line.text_range.start < 0 || line.text_range.end < line.text_range.start ||
            line.text_range.end > text_count ||
            static_cast<std::size_t>(line.text_range.end) >= offsets.size())
            return false;
        const std::size_t start = offsets[static_cast<std::size_t>(line.text_range.start)];
        const std::size_t end = offsets[static_cast<std::size_t>(line.text_range.end)];
        retained->line_ranges.push_back(line.text_range);
        retained->line_revisions.push_back(++state_->line_revision_sequence);
        const float top = std::min(line.bounds.y, line.culling_bounds.y);
        const float bottom = std::max(line.bounds.y + line.bounds.height,
                                       line.culling_bounds.y + line.culling_bounds.height);
        retained->prefix_bottoms.push_back(index == 0 ? bottom
            : std::max(bottom, retained->prefix_bottoms.back()));
        retained->suffix_tops.push_back(top);
        layout_result.lines.push_back(
            {start,
             end - start,
             {line.bounds.x, line.bounds.y, line.bounds.width, line.bounds.height}});
    }
    for (int32_t i = lines_count - 2; i >= 0; --i)
        retained->suffix_tops[i] = std::min(retained->suffix_tops[i], retained->suffix_tops[i + 1]);
    retained->result = std::move(layout_result);
    state_->active_layout_id = layout_id;
    if (result)
        *result = retained->result;
    state_->layouts.emplace(layout_id, std::move(retained));
    ++state_->layout_builds;
    return true;
}

static bool same_rendered_line(const skb_layout_t *previous, const skb_layout_t *next,
                               int32_t old_index, int32_t new_index) {
    const auto a = skb_layout_get_line_at(previous, old_index);
    const auto b = skb_layout_get_line_at(next, new_index);
    const auto same_bounds = [](skb_rect2_t x, skb_rect2_t y) {
        return x.x == y.x && x.y == y.y && x.width == y.width && x.height == y.height;
    };
    // Require exact row-local geometry. Fractional origin subtraction can
    // differ after movement; those rows conservatively receive new revisions.
    const int32_t count = a.text_range.end - a.text_range.start;
    if (count != b.text_range.end - b.text_range.start ||
        a.bounds.width != b.bounds.width || a.bounds.height != b.bounds.height ||
        a.baseline - a.bounds.y != b.baseline - b.bounds.y ||
        a.layout_run_range.end - a.layout_run_range.start !=
            b.layout_run_range.end - b.layout_run_range.start)
        return false;
    for (int32_t i = 0; i < count; ++i) {
        if (skb_layout_get_text_at(previous, a.text_range.start + i) !=
            skb_layout_get_text_at(next, b.text_range.start + i))
            return false;
    }
    for (int32_t run = 0; run < a.layout_run_range.end - a.layout_run_range.start; ++run) {
        const auto x = skb_layout_get_layout_run_at(previous, a.layout_run_range.start + run);
        const auto y = skb_layout_get_layout_run_at(next, b.layout_run_range.start + run);
        auto old_bounds = x.bounds;
        auto new_bounds = y.bounds;
        old_bounds.x -= a.bounds.x;
        old_bounds.y -= a.bounds.y;
        new_bounds.x -= b.bounds.x;
        new_bounds.y -= b.bounds.y;
        if ((x.type != SKB_CONTENT_RUN_UTF8 && x.type != SKB_CONTENT_RUN_UTF32) ||
            x.type != y.type || x.direction != y.direction || x.script != y.script ||
            x.bidi_level != y.bidi_level || x.font_handle != y.font_handle ||
            x.font_size != y.font_size || x.flags != y.flags ||
            x.ref_baseline - a.bounds.y != y.ref_baseline - b.bounds.y ||
            !same_bounds(old_bounds, new_bounds) ||
            x.glyph_range.end - x.glyph_range.start != y.glyph_range.end - y.glyph_range.start)
            return false;
        for (int32_t glyph = 0; glyph < x.glyph_range.end - x.glyph_range.start; ++glyph) {
            const auto p = skb_layout_get_glyph_at(previous, x.glyph_range.start + glyph);
            const auto q = skb_layout_get_glyph_at(next, y.glyph_range.start + glyph);
            if (p.gid != q.gid || p.advance_x != q.advance_x ||
                p.offset_x - a.bounds.x != q.offset_x - b.bounds.x ||
                p.offset_y - a.bounds.y != q.offset_y - b.bounds.y ||
                p.cluster_idx < 0 || q.cluster_idx < 0 ||
                p.cluster_idx >= skb_layout_get_clusters_count(previous) ||
                q.cluster_idx >= skb_layout_get_clusters_count(next))
                return false;
            const auto pc = skb_layout_get_cluster_at(previous, p.cluster_idx);
            const auto qc = skb_layout_get_cluster_at(next, q.cluster_idx);
            if (pc.text_offset - a.text_range.start != qc.text_offset - b.text_range.start ||
                pc.text_count != qc.text_count || pc.glyphs_count != qc.glyphs_count)
                return false;
        }
    }
    return true;
}

bool TextEngine::edit_utf8(int32_t start, int32_t end, const char *replacement,
                           TextLayoutResult *result) {
    auto *current = active_layout(*state_);
    if (!current || start < 0 || end < start || !replacement)
        return false;
    TextScratchScope scratch(state_->temporary);
    std::size_t byte_start = 0;
    std::size_t byte_end = 0;
    if (!utf8_byte_range(current->text, start, end, byte_start, byte_end))
        return false;
    std::string edited;
    edited.reserve(current->text.size() + std::strlen(replacement));
    edited.append(current->text, 0, byte_start);
    edited.append(replacement);
    edited.append(current->text, byte_end, std::string::npos);
    auto edited_layout = own_native_layout(
        skb_layout_create_ascii_edit(current->layout.get(), state_->temporary,
                                     start, end, replacement, -1), state_->font_collection);
    if (edited_layout) {
        current->layout = std::move(edited_layout);
        std::string previous_text = std::move(current->text);
        current->text = std::move(edited);
        current->last_used = ++state_->layout_use_sequence;
        auto &layout_result = current->result;
        const skb_rect2_t bounds = skb_layout_get_bounds(current->layout.get());
        layout_result.bounds = {bounds.x, bounds.y, bounds.width, bounds.height};
        const int32_t line_count = skb_layout_get_lines_count(current->layout.get());
        std::vector<uint64_t> next_line_revisions;
        next_line_revisions.reserve(static_cast<std::size_t>(line_count));
        for (int32_t index = 0; index < line_count; ++index) {
            const auto line = skb_layout_get_line_at(current->layout.get(), index);
            const auto &old_range = index < static_cast<int32_t>(current->line_ranges.size())
                ? current->line_ranges[index] : line.text_range;
            const bool unchanged_text = line.text_range.start >= 0 &&
                line.text_range.end >= line.text_range.start &&
                old_range.start >= 0 && old_range.end >= old_range.start &&
                line.text_range.end - line.text_range.start == old_range.end - old_range.start &&
                static_cast<std::size_t>(old_range.end) <= previous_text.size() &&
                static_cast<std::size_t>(line.text_range.end) <= current->text.size() &&
                std::memcmp(previous_text.data() + old_range.start,
                            current->text.data() + line.text_range.start,
                            static_cast<std::size_t>(line.text_range.end - line.text_range.start)) == 0;
            const bool reusable = index < static_cast<int32_t>(current->line_ranges.size()) &&
                index < static_cast<int32_t>(current->line_revisions.size()) &&
                index < static_cast<int32_t>(layout_result.lines.size()) &&
                unchanged_text &&
                line.bounds.x == layout_result.lines[index].bounds.x &&
                line.bounds.y == layout_result.lines[index].bounds.y &&
                line.bounds.width == layout_result.lines[index].bounds.width &&
                line.bounds.height == layout_result.lines[index].bounds.height;
            next_line_revisions.push_back(reusable ? current->line_revisions[index]
                : ++state_->line_revision_sequence);
        }
        current->line_revisions = std::move(next_line_revisions);
        layout_result.lines.clear();
        current->line_ranges.clear();
        current->prefix_bottoms.clear();
        current->suffix_tops.clear();
        layout_result.lines.reserve(static_cast<std::size_t>(line_count));
        current->line_ranges.reserve(static_cast<std::size_t>(line_count));
        for (int32_t index = 0; index < line_count; ++index) {
            const auto line = skb_layout_get_line_at(current->layout.get(), index);
            current->line_ranges.push_back(line.text_range);
            const float top = std::min(line.bounds.y, line.culling_bounds.y);
            const float bottom = std::max(line.bounds.y + line.bounds.height,
                                           line.culling_bounds.y + line.culling_bounds.height);
            current->prefix_bottoms.push_back(index == 0 ? bottom
                : std::max(bottom, current->prefix_bottoms.back()));
            current->suffix_tops.push_back(top);
            // The guarded native path accepts only one-byte lowercase ASCII.
            layout_result.lines.push_back({static_cast<std::size_t>(line.text_range.start),
                static_cast<std::size_t>(line.text_range.end - line.text_range.start),
                {line.bounds.x, line.bounds.y, line.bounds.width, line.bounds.height}});
        }
        for (int32_t index = line_count - 2; index >= 0; --index)
            current->suffix_tops[index] = std::min(current->suffix_tops[index],
                                                    current->suffix_tops[index + 1]);
        ++state_->incremental_ascii_edits;
        ++state_->layout_builds;
        if (std::getenv("NKUI_TRACE_ASCII_EDIT"))
            std::fprintf(stderr, "nkui edit: reused ASCII shaping, %d codepoints, %d rows\n",
                         skb_layout_get_text_count(current->layout.get()), line_count);
        if (result)
            *result = layout_result;
        return true;
    }
    ++state_->edit_layout_fallbacks;
    if (std::getenv("NKUI_TRACE_ASCII_EDIT"))
        std::fprintf(stderr, "nkui edit: full-layout fallback\n");
    if (!layout_utf8(edited.c_str(), current->width, current->options, result))
        return false;
    auto *rebuilt = active_layout(*state_);
    if (rebuilt && rebuilt->font_generation == current->font_generation) {
        const int32_t delta = skb_layout_get_text_count(rebuilt->layout.get()) -
                              skb_layout_get_text_count(current->layout.get());
        for (std::size_t row = 0; row < rebuilt->line_ranges.size(); ++row) {
            const auto range = rebuilt->line_ranges[row];
            const bool prefix = range.end <= start;
            const bool suffix = range.start >= end + delta;
            if (!prefix && !suffix)
                continue;
            const int32_t shift = prefix ? 0 : delta;
            const int32_t old_start = range.start - shift;
            const auto found = std::lower_bound(current->line_ranges.begin(),
                current->line_ranges.end(), old_start,
                [](skb_range_t line, int32_t offset) { return line.start < offset; });
            if (found == current->line_ranges.end() || found->start != old_start ||
                found->end != range.end - shift)
                continue;
            const auto old_row = static_cast<std::size_t>(found - current->line_ranges.begin());
            if (same_rendered_line(current->layout.get(), rebuilt->layout.get(),
                                   static_cast<int32_t>(old_row), static_cast<int32_t>(row)))
                rebuilt->line_revisions[row] = current->line_revisions[old_row];
        }
    }
    return true;
}

void TextEngine::prune_layout_cache(const std::vector<TextLayoutId> &retained_ids,
                                    std::size_t max_entries) {
    const uint64_t font_generation = state_->font_collection->generation();
    const std::unordered_set<TextLayoutId> retained(retained_ids.begin(), retained_ids.end());

    for (auto entry = state_->layouts.begin(); entry != state_->layouts.end();) {
        if (entry->second->font_generation != font_generation &&
            retained.find(entry->first) == retained.end())
            entry = state_->layouts.erase(entry);
        else
            ++entry;
    }

    while (state_->layouts.size() > max_entries) {
        auto oldest = state_->layouts.end();
        for (auto entry = state_->layouts.begin(); entry != state_->layouts.end(); ++entry) {
            if (retained.find(entry->first) != retained.end())
                continue;
            if (oldest == state_->layouts.end() ||
                entry->second->last_used < oldest->second->last_used)
                oldest = entry;
        }
        if (oldest == state_->layouts.end())
            break;
        state_->layouts.erase(oldest);
    }
}

bool TextEngine::has_layout(TextLayoutId id) const {
    return id != 0 && find_layout(*state_, id) != nullptr;
}

bool TextEngine::prepare_glyphs(float origin_x, float origin_y, float pixel_scale, GlyphMode mode,
                                PreparedGlyphs &output) {
    return prepare_glyphs_internal(state_->active_layout_id, origin_x, origin_y, pixel_scale, mode,
                                   output, -1, -1, 0.0f, 0.0f);
}

std::pair<uint32_t, uint32_t> TextEngine::visible_lines(float min_y, float max_y) const {
    const auto *layout = active_layout(*state_);
    if (!layout || max_y <= min_y)
        return {0, 0};
    const auto first = std::upper_bound(layout->prefix_bottoms.begin(),
                                         layout->prefix_bottoms.end(), min_y);
    const auto end = std::lower_bound(layout->suffix_tops.begin(),
                                       layout->suffix_tops.end(), max_y);
    const auto begin_index = static_cast<uint32_t>(first - layout->prefix_bottoms.begin());
    return {begin_index, std::max(begin_index,
        static_cast<uint32_t>(end - layout->suffix_tops.begin()))};
}

std::vector<TextRect> TextEngine::line_rects(int32_t start, int32_t end, float min_y,
                                             float max_y) const {
    std::vector<TextRect> rectangles;
    const auto *layout = active_layout(*state_);
    if (!layout || start >= end || max_y <= min_y)
        return rectangles;
    const auto [first, last] = visible_lines(min_y, max_y);
    rectangles.reserve(last - first);
    for (uint32_t index = first; index < last; ++index) {
        const auto range = layout->line_ranges[index];
        if (range.end <= start || range.start >= end)
            continue;
        rectangles.push_back(layout->result.lines[index].bounds);
    }
    return rectangles;
}

TextRect TextEngine::line_bounds(uint32_t index) const {
    const auto *layout = active_layout(*state_);
    return layout && index < layout->result.lines.size()
        ? layout->result.lines[index].bounds : TextRect{};
}

bool TextEngine::prepare_glyphs_for_lines(uint32_t first, uint32_t end, float origin_x,
                                          float origin_y, float pixel_scale, GlyphMode mode,
                                          PreparedGlyphs &output) {
    const auto *layout = active_layout(*state_);
    if (!layout || first > end || end > layout->result.lines.size())
        return false;
    return prepare_glyphs_internal(state_->active_layout_id, origin_x, origin_y, pixel_scale,
                                    mode, output, -1, -1, 0, 0,
                                    static_cast<int32_t>(first), static_cast<int32_t>(end));
}

std::shared_ptr<const PreparedGlyphs> TextEngine::published_glyphs_for_lines(
    TextLayoutId id, uint32_t first, uint32_t end, float origin_x, float origin_y,
    float pixel_scale, GlyphMode mode, GlyphTint tint, const std::vector<GlyphColorRange> &ranges) {
    const auto *layout = find_layout(*state_, id);
    if (!layout || first > end || end > layout->result.lines.size())
        return {};
    return publish_glyphs(id, static_cast<int32_t>(first), origin_x, origin_y,
                          pixel_scale, mode, tint, ranges, static_cast<int32_t>(end));
}

bool TextEngine::prepare_glyphs_for_line(uint32_t line_index, float origin_x, float origin_y,
                                         float pixel_scale, GlyphMode mode,
                                         PreparedGlyphs &output) {
    return prepare_glyphs_for_line(state_->active_layout_id, line_index, origin_x, origin_y,
                                   pixel_scale, mode, output);
}

bool TextEngine::prepare_glyphs_for_line(TextLayoutId id, uint32_t line_index, float origin_x,
                                         float origin_y, float pixel_scale, GlyphMode mode,
                                         PreparedGlyphs &output, GlyphPreparation preparation) {
    const auto *layout = find_layout(*state_, id);
    if (!layout || line_index >= layout->result.lines.size() ||
        line_index >= layout->line_ranges.size())
        return false;
    const auto &line = layout->result.lines[line_index];
    const auto range = layout->line_ranges[line_index];
    return prepare_glyphs_internal(id, origin_x, origin_y, pixel_scale, mode, output, range.start,
                                   range.end, line.bounds.x, line.bounds.y, static_cast<int32_t>(line_index), -1,
                                   preparation);
}

std::shared_ptr<const PreparedGlyphs> TextEngine::published_glyphs(TextLayoutId id, float origin_x,
                                                                   float origin_y,
                                                                   float pixel_scale,
                                                                   GlyphMode mode, GlyphTint tint,
                                                                   const std::vector<GlyphColorRange> &ranges,
                                                                   GlyphPreparation preparation) {
    return publish_glyphs(id, -1, origin_x, origin_y, pixel_scale, mode, tint, ranges, -1, preparation);
}

std::shared_ptr<const PreparedGlyphs>
TextEngine::published_glyphs_for_line(TextLayoutId id, uint32_t line_index, float origin_x,
                                      float origin_y, float pixel_scale, GlyphMode mode,
                                      GlyphTint tint, const std::vector<GlyphColorRange> &ranges,
                                      GlyphPreparation preparation) {
    return publish_glyphs(id, static_cast<int32_t>(line_index), origin_x, origin_y, pixel_scale,
                          mode, tint, ranges, -1, preparation);
}

std::shared_ptr<const PreparedGlyphs> TextEngine::publish_glyphs(TextLayoutId id,
                                                                 int32_t line_index, float origin_x,
                                                                 float origin_y, float pixel_scale,
                                                                 GlyphMode mode, GlyphTint tint,
                                                                   const std::vector<GlyphColorRange> &ranges, int32_t end_line,
                                                                   GlyphPreparation preparation) {
    const auto *layout = find_layout(*state_, id);
    const auto raster_scale = text_raster_scale(pixel_scale);
    if (!layout || !raster_scale.key || !std::isfinite(origin_x) ||
        !std::isfinite(origin_y) || !valid_glyph_color_ranges(ranges))
        return {};
    pixel_scale = raster_scale.value;
    if (line_index >= 0 && end_line < 0 && static_cast<std::size_t>(line_index) >= layout->result.lines.size())
        return {};

    TextScratchScope scratch(state_->temporary);
    const bool single_line = line_index >= 0 && end_line < 0 &&
        static_cast<std::size_t>(line_index) < layout->line_revisions.size();
    // Row revisions are unique within this engine and may survive a fresh
    // Unicode layout. Keep their paint identity independent of layout IDs.
    auto key = single_line ? uint64_t{0} : static_cast<uint64_t>(id);
    const auto mix = [&key](uint64_t value) {
        key ^= value + 0x9e3779b97f4a7c15ull + (key << 6) + (key >> 2);
    };
    mix(single_line ? 1u : 0u);
    mix(single_line ? layout->line_revisions[line_index]
                    : skb_layout_get_generation(layout->layout.get()));
    mix(font_collection_generation());
    mix(raster_scale.key);
    mix(static_cast<uint64_t>(mode));
    if (!single_line) {
        mix(static_cast<uint64_t>(line_index + 1));
        mix(static_cast<uint64_t>(end_line + 1));
    }
    // Origins remain unrounded in geometry, so their cache identity must too.
    const auto mix_origin = [&mix](float origin) {
        uint32_t bits = 0;
        if (origin != 0.0f) // Normalize positive and negative zero.
            std::memcpy(&bits, &origin, sizeof(bits));
        mix(bits);
    };
    mix_origin(origin_x);
    mix_origin(origin_y);
    mix(static_cast<uint64_t>(tint.red) << 24 | static_cast<uint64_t>(tint.green) << 16 |
        static_cast<uint64_t>(tint.blue) << 8 | static_cast<uint64_t>(tint.alpha));

    std::vector<GlyphColorRange> relevant_ranges;
    for (auto range : ranges) {
        if (line_index >= 0) {
            if (end_line == line_index)
                continue;
            const skb_range_t line = end_line < 0 ? layout->line_ranges[line_index]
                : skb_range_t{layout->line_ranges[line_index].start,
                              layout->line_ranges[end_line - 1].end};
            range.start = std::max(range.start, line.start);
            range.end = std::min(range.end, line.end);
            if (range.start >= range.end)
                continue;
        }
        relevant_ranges.push_back(range);
        const int32_t color_origin = single_line ? layout->line_ranges[line_index].start : 0;
        mix(static_cast<uint64_t>(range.start - color_origin));
        mix(static_cast<uint64_t>(range.end - color_origin));
        mix(static_cast<uint64_t>(range.tint.red) << 24 |
            static_cast<uint64_t>(range.tint.green) << 16 |
            static_cast<uint64_t>(range.tint.blue) << 8 | range.tint.alpha);
    }

    if (const auto found = state_->published_glyphs.find(key);
        found != state_->published_glyphs.end()) {
        if (auto cached = found->second.lock()) {
            if (single_line && cached->source_start >= 0 &&
                (cached->layout_id != id ||
                 cached->first_line != line_index ||
                 cached->source_start != layout->line_ranges[line_index].start) &&
                cached->line_revision == layout->line_revisions[line_index]) {
                const int32_t delta = layout->line_ranges[line_index].start - cached->source_start;
                auto rebased = std::make_shared<PreparedGlyphs>(*cached);
                rebased->layout_id = id;
                rebased->layout_generation = skb_layout_get_generation(layout->layout.get());
                rebased->first_line = line_index;
                rebased->end_line = line_index + 1;
                rebased->source_start += delta;
                for (auto &source : rebased->source_ranges) {
                    source.start += delta;
                    source.end += delta;
                }
                if (prepared_glyphs_current(*rebased)) {
                    state_->published_glyphs[key] = rebased;
                    return rebased;
                }
            }
            if (prepared_glyphs_current(*cached))
                return cached;
        }
    }

    auto snapshot = std::make_shared<PreparedGlyphs>();
    if (!snapshot)
        return {};
    const bool prepared =
        end_line >= 0 ? prepare_glyphs_internal(id, origin_x, origin_y, pixel_scale, mode,
                                                *snapshot, -1, -1, 0, 0, line_index, end_line, preparation)
        : line_index < 0 ? prepare_glyphs_internal(id, origin_x, origin_y, pixel_scale, mode,
                                                 *snapshot, -1, -1, 0.0f, 0.0f, -1, -1, preparation)
                       : prepare_glyphs_for_line(id, static_cast<uint32_t>(line_index), origin_x,
                                                 origin_y, pixel_scale, mode, *snapshot, preparation);
    if (!prepared)
        return {};

    /* Color only the newly built snapshot, before publishing it. */
    apply_glyph_colors(*snapshot, tint, relevant_ranges);
    snapshot->publication_key = key;

    /* Weak entries keep live snapshots shared and let the rest expire. */
    if (state_->published_glyphs.size() >= 256) {
        for (auto entry = state_->published_glyphs.begin();
             entry != state_->published_glyphs.end();) {
            if (entry->second.expired())
                entry = state_->published_glyphs.erase(entry);
            else
                ++entry;
        }
    }
    state_->published_glyphs[key] = snapshot;
    return snapshot;
}

bool TextEngine::prepare_glyphs_internal(TextLayoutId id, float origin_x, float origin_y,
                                         float pixel_scale, GlyphMode mode, PreparedGlyphs &output,
                                         int32_t line_start, int32_t line_end, float line_x,
                                         float line_y, int32_t line_index, int32_t end_line,
                                         GlyphPreparation preparation) {
    const auto *retained = find_layout(*state_, id);
    const auto raster_scale = text_raster_scale(pixel_scale);
    if (!retained || !raster_scale.key || !std::isfinite(origin_x) || !std::isfinite(origin_y))
        return false;
    pixel_scale = raster_scale.value;
    TextScratchScope scratch(state_->temporary);
    const uint32_t scale_key = static_cast<uint32_t>(raster_scale.key);
    if (state_->last_scale_key != scale_key) {
        state_->last_scale_key = scale_key;
        ++state_->scale_generation;
        if (!state_->scale_generation)
            ++state_->scale_generation;
    }
    output = {};
    output.origin_x = origin_x;
    output.origin_y = origin_y;
    output.pixel_scale = pixel_scale;
    output.mode = mode;
    output.layout_id = id;
    output.first_line = line_index;
    output.end_line = end_line < 0 ? line_index + 1 : end_line;
    output.layout_generation = skb_layout_get_generation(retained->layout.get());
    output.line_revision = line_index >= 0 && end_line < 0 &&
        static_cast<std::size_t>(line_index) < retained->line_revisions.size()
        ? retained->line_revisions[line_index] : 0;
    if (output.line_revision)
        output.source_start = retained->line_ranges[line_index].start;
    if (!state_->font_collection || !state_->font_collection->state_ ||
        !state_->font_collection->state_->fonts)
        return false;
    const skb_range_t lines = line_index < 0
        ? skb_range_t{0, skb_layout_get_lines_count(retained->layout.get())}
        : skb_range_t{line_index, end_line < 0 ? line_index + 1 : end_line};
    if (preparation == GlyphPreparation::Rasterize &&
        !skb_layout_prepare_glyphs_range(retained->layout.get(), lines, state_->atlas, state_->temporary,
                                         state_->rasterizer, pixel_scale, raster_mode(mode)))
        return false;
    if (std::getenv("NKUI_DEBUG_GLYPHS") && retained->options.font_size == 18.0f) {
        const int32_t count = skb_layout_get_text_count(retained->layout.get());
        std::fprintf(stderr, "text properties:");
        for (int32_t i = 0; i < count; ++i) {
            const uint32_t script = skb_script_to_iso15924_tag(
                skb_layout_get_text_property_at(retained->layout.get(), i).script);
            std::fprintf(stderr, " %x/%c%c%c%c", skb_layout_get_text_at(retained->layout.get(), i),
                         static_cast<char>(script >> 24),
                         static_cast<char>(script >> 16), static_cast<char>(script >> 8),
                         static_cast<char>(script));
        }
        std::fprintf(stderr, "\n");
    }
    RenderGlyphContext render{state_,
                              state_->font_collection->state_->fonts,
                              retained->layout.get(),
                              origin_x - line_x,
                              origin_y - line_y,
                              pixel_scale,
                              mode,
                              &output,
                              line_start,
                              line_end};
    if (!skb_layout_iterate_render_glyphs_range(retained->layout.get(), lines, append_render_glyph, &render))
        return false;
    state_->prepared_batch_count += output.batches.size();
    return true;
}

bool TextEngine::prepared_glyphs_current(const PreparedGlyphs &glyphs) const {
    const auto *layout = find_layout(*state_, glyphs.layout_id);
    if (!state_->atlas || !layout)
        return false;
    if (glyphs.line_revision != 0) {
        if (glyphs.first_line < 0 || glyphs.end_line != glyphs.first_line + 1 ||
            static_cast<std::size_t>(glyphs.first_line) >= layout->line_revisions.size() ||
            glyphs.line_revision != layout->line_revisions[glyphs.first_line] ||
            glyphs.source_start != layout->line_ranges[glyphs.first_line].start)
            return false;
    } else if (glyphs.layout_generation != skb_layout_get_generation(layout->layout.get()))
        return false;
    const int count = skb_image_atlas_get_texture_count(state_->atlas);
    for (const auto &batch : glyphs.batches) {
        bool found = false;
        for (int index = 0; index < count; ++index) {
            if (skb_image_atlas_get_texture_user_data(state_->atlas, index) != batch.atlas.value)
                continue;
            found = true;
            if (skb_image_atlas_get_texture_generation(state_->atlas, index) !=
                batch.atlas_generation)
                return false;
            break;
        }
        if (!found)
            return false;
    }
    return true;
}

int32_t TextEngine::text_count() const {
    const auto *layout = find_layout(*state_, active_layout_id());
    return layout ? skb_layout_get_text_count(layout->layout.get()) : 0;
}

TextRect TextEngine::bounds() const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return {};
    const skb_rect2_t value = skb_layout_get_bounds(layout->layout.get());
    return {value.x, value.y, value.width, value.height};
}

TextPosition TextEngine::hit_test(float x, float y) const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return {};
    const skb_text_position_t value = skb_layout_hit_test(layout->layout.get(), SKB_MOVEMENT_CARET, x, y);
    return {value.offset, static_cast<uint8_t>(value.affinity)};
}

int32_t TextEngine::offset_from_position(TextPosition position) const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return 0;
    const skb_text_position_t value = {position.offset,
                                       static_cast<skb_caret_affinity_t>(position.affinity)};
    return skb_layout_get_offset_from_text_position(layout->layout.get(), value);
}

TextCaret TextEngine::caret(TextPosition position) const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return {};
    const skb_text_position_t value = {position.offset,
                                       static_cast<skb_caret_affinity_t>(position.affinity)};
    const skb_caret_info_t result = skb_layout_get_caret_info_at(layout->layout.get(), value);
    return {result.x, result.y, result.ascender, result.descender, result.slope, result.direction};
}

TextPosition TextEngine::word_start(TextPosition position) const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return {};
    const skb_text_position_t input = {position.offset,
                                       static_cast<skb_caret_affinity_t>(position.affinity)};
    const skb_text_position_t result = skb_layout_get_word_start_at(layout->layout.get(), input);
    return {result.offset, static_cast<uint8_t>(result.affinity)};
}

TextPosition TextEngine::word_end(TextPosition position) const {
    const auto *layout = active_layout(*state_);
    if (!layout)
        return {};
    const skb_text_position_t input = {position.offset,
                                       static_cast<skb_caret_affinity_t>(position.affinity)};
    const skb_text_position_t result = skb_layout_get_word_end_at(layout->layout.get(), input);
    return {result.offset, static_cast<uint8_t>(result.affinity)};
}

int32_t TextEngine::next_grapheme(int32_t offset) const {
    const auto *layout = active_layout(*state_);
    return layout ? skb_layout_get_next_grapheme_offset(layout->layout.get(), offset) : 0;
}

int32_t TextEngine::previous_grapheme(int32_t offset) const {
    const auto *layout = active_layout(*state_);
    return layout ? skb_layout_get_prev_grapheme_offset(layout->layout.get(), offset) : 0;
}

int32_t TextEngine::align_grapheme(int32_t offset) const {
    const auto *layout = active_layout(*state_);
    return layout ? skb_layout_align_grapheme_offset(layout->layout.get(), offset) : 0;
}

TextRange TextEngine::word_range_at(int32_t offset) const {
    const auto *retained = active_layout(*state_);
    if (!retained)
        return {};
    const skb_layout_t *layout = retained->layout.get();
    const int32_t text_count = skb_layout_get_text_count(layout);
    if (text_count <= 0)
        return {};

    const int32_t safe_offset = std::clamp(offset, 0, text_count);
    const skb_text_position_t position{safe_offset, SKB_AFFINITY_LEADING};
    const skb_text_position_t start = skb_layout_get_word_start_at(layout, position);
    const skb_text_position_t inclusive_end = skb_layout_get_word_end_at(layout, position);
    const int32_t end = inclusive_end.offset < text_count
                            ? skb_layout_get_next_grapheme_offset(layout, inclusive_end.offset)
                            : text_count;
    return {std::min(start.offset, end), std::max(start.offset, end)};
}

TextRange TextEngine::line_range_at(int32_t offset) const {
    const auto *retained = active_layout(*state_);
    if (!retained)
        return {};
    const skb_layout_t *layout = retained->layout.get();
    const int32_t text_count = skb_layout_get_text_count(layout);
    if (text_count <= 0)
        return {};

    const int32_t safe_offset = std::clamp(offset, 0, text_count);
    const skb_text_position_t position{safe_offset, SKB_AFFINITY_LEADING};
    const skb_text_position_t start = skb_layout_get_line_start_at(layout, position);
    const skb_text_position_t inclusive_end = skb_layout_get_line_end_at(layout, position);
    const int32_t end = inclusive_end.offset < text_count
                            ? skb_layout_get_next_grapheme_offset(layout, inclusive_end.offset)
                            : text_count;
    return {std::min(start.offset, end), std::max(start.offset, end)};
}

int32_t TextEngine::move_word(int32_t offset, int32_t direction, bool mac_style) const {
    const auto *retained = active_layout(*state_);
    if (!retained || direction == 0)
        return offset;

    const skb_layout_t *layout = retained->layout.get();
    const int32_t text_count = skb_layout_get_text_count(layout);
    if (text_count <= 0)
        return 0;

    int32_t next = std::clamp(offset, 0, text_count);
    const auto next_grapheme = [layout](int32_t value) {
        return skb_layout_get_next_grapheme_offset(layout, value);
    };
    const auto previous_grapheme = [layout](int32_t value) {
        return skb_layout_get_prev_grapheme_offset(layout, value);
    };
    constexpr uint8_t word_break = SKB_TEXT_PROP_WORD_BREAK;
    constexpr uint8_t whitespace = SKB_TEXT_PROP_WHITESPACE;
    constexpr uint8_t punctuation = SKB_TEXT_PROP_PUNCTUATION;

    if (direction > 0) {
        if (mac_style) {
            while (next < text_count &&
                   (skb_layout_get_text_property_at(layout, next).flags & (whitespace | punctuation)) != 0)
                next++;
            while (next < text_count) {
                if ((skb_layout_get_text_property_at(layout, next).flags & word_break) != 0) {
                    next = next_grapheme(next);
                    break;
                }
                next++;
            }
        } else {
            while (next < text_count) {
                if ((skb_layout_get_text_property_at(layout, next).flags & word_break) != 0) {
                    const int32_t after_boundary = next_grapheme(next);
                    if (after_boundary >= text_count ||
                        (skb_layout_get_text_property_at(layout, after_boundary).flags & whitespace) == 0) {
                        next = after_boundary;
                        break;
                    }
                }
                next++;
            }
        }
    } else {
        if (mac_style) {
            while (next > 0 &&
                   (skb_layout_get_text_property_at(layout, next - 1).flags & (whitespace | punctuation)) != 0)
                next--;
        }
        if (next > 0)
            next = previous_grapheme(next);
        while (next > 0) {
            if ((skb_layout_get_text_property_at(layout, next - 1).flags & word_break) != 0) {
                const int32_t after_boundary = next_grapheme(next - 1);
                if (mac_style || after_boundary >= text_count ||
                    (skb_layout_get_text_property_at(layout, after_boundary).flags & whitespace) == 0) {
                    next = after_boundary;
                    break;
                }
            }
            next--;
        }
    }

    return std::clamp(skb_layout_align_grapheme_offset(layout, next), 0, text_count);
}

int32_t TextEngine::move_paragraph(int32_t offset, int32_t direction, bool mac_style) const {
    const auto *retained = active_layout(*state_);
    if (!retained || direction == 0)
        return offset;

    const skb_layout_t *layout = retained->layout.get();
    const int32_t text_count = skb_layout_get_text_count(layout);
    if (text_count <= 0)
        return 0;
    const int32_t current = std::clamp(offset, 0, text_count);
    int32_t paragraph_start = 0;
    for (int32_t index = 0; index < current; ++index) {
        if ((skb_layout_get_text_property_at(layout, index).flags & SKB_TEXT_PROP_MUST_LINE_BREAK) != 0)
            paragraph_start = index + 1;
    }

    int32_t paragraph_end = text_count;
    for (int32_t index = current; index < text_count; ++index) {
        if ((skb_layout_get_text_property_at(layout, index).flags & SKB_TEXT_PROP_MUST_LINE_BREAK) != 0) {
            paragraph_end = index;
            break;
        }
    }

    if (mac_style)
        return direction < 0 ? paragraph_start : paragraph_end;
    if (direction > 0)
        return paragraph_end < text_count ? paragraph_end + 1 : text_count;

    int32_t previous_start = 0;
    for (int32_t index = 0; index + 1 < paragraph_start; ++index) {
        if ((skb_layout_get_text_property_at(layout, index).flags & SKB_TEXT_PROP_MUST_LINE_BREAK) != 0)
            previous_start = index + 1;
    }
    return previous_start;
}

std::vector<TextRect> TextEngine::selection_rects(TextPosition start, TextPosition end) const {
    std::vector<TextRect> rectangles;
    const auto *layout = active_layout(*state_);
    if (!layout)
        return rectangles;
    const auto generation = skb_layout_get_generation(layout->layout.get());
    if (state_->selection_layout_id == state_->active_layout_id &&
        state_->selection_layout_generation == generation &&
        state_->selection_start.offset == start.offset &&
        state_->selection_start.affinity == start.affinity &&
        state_->selection_end.offset == end.offset &&
        state_->selection_end.affinity == end.affinity)
        return state_->selection_rectangles;
    const skb_text_range_t range = {
        {start.offset, static_cast<skb_caret_affinity_t>(start.affinity)},
        {end.offset, static_cast<skb_caret_affinity_t>(end.affinity)}};
    const auto collect = [](skb_rect2_t rect, void *context) {
        static_cast<std::vector<TextRect> *>(context)->push_back(
            {rect.x, rect.y, rect.width, rect.height});
    };
    skb_layout_iterate_text_range_bounds(layout->layout.get(), range, collect, &rectangles);

    // Replace font-dependent control-character advances with a compact marker.
    // This affects selection painting only; offsets, shaping and caret geometry
    // continue to include the original line-break grapheme (including CRLF).
    struct BreakSpan {
        float left, right, top;
        TextRect marker;
    };
    std::vector<BreakSpan> break_spans;
    struct BreakSelectionContext {
        const skb_layout_t *layout;
        skb_range_t selected;
        std::vector<BreakSpan> *spans;
    } breaks{layout->layout.get(),
             skb_layout_get_offset_range_from_text_range(layout->layout.get(), range),
             &break_spans};
    const auto collect_break = [](const skb_layout_render_glyph_t *glyph, void *context) {
        auto &value = *static_cast<BreakSelectionContext *>(context);
        if (glyph->text_range.end <= value.selected.start ||
            glyph->text_range.start >= value.selected.end ||
            !is_line_break_glyph(value.layout, *glyph))
            return true;
        const auto position = skb_text_position_t{glyph->text_range.start,
                                                  static_cast<skb_caret_affinity_t>(0)};
        const auto line = skb_layout_get_line_at(value.layout,
                                                 skb_layout_get_line_index(value.layout, position));
        const float top = line.baseline + line.ascender;
        const float height = line.descender - line.ascender;
        const float left = glyph->offset_x;
        const float right = left + std::max(0.0f, glyph->advance_x);
        const float marker_width = std::max(1.0f, glyph->font_size * 0.25f);
        const float marker_x = skb_is_rtl(static_cast<skb_text_direction_t>(glyph->direction)) ? right - marker_width : left;
        value.spans->push_back({left, right, top, {marker_x, top, marker_width, height}});
        return true;
    };
    const int32_t first_line = skb_layout_get_line_index(layout->layout.get(), range.start);
    const int32_t last_line = skb_layout_get_line_index(layout->layout.get(), range.end);
    skb_layout_iterate_render_glyphs_range(layout->layout.get(),
        {std::min(first_line, last_line), std::max(first_line, last_line) + 1},
        collect_break, &breaks);
    if (!break_spans.empty()) {
        std::sort(break_spans.begin(), break_spans.end(), [](const BreakSpan &a, const BreakSpan &b) {
            return a.top != b.top ? a.top < b.top : a.left < b.left;
        });
        std::vector<TextRect> text_rectangles;
        text_rectangles.reserve(rectangles.size() + break_spans.size());
        constexpr float epsilon = 0.01f;
        for (const auto &rect : rectangles) {
            auto span = std::lower_bound(break_spans.begin(), break_spans.end(), rect.y - epsilon,
                [](const BreakSpan &item, float top) { return item.top < top; });
            float cursor = rect.x;
            const float right = rect.x + rect.width;
            for (; span != break_spans.end() && span->top <= rect.y + epsilon; ++span) {
                if (span->right <= cursor || span->left >= right) continue;
                if (span->left > cursor)
                    text_rectangles.push_back({cursor, rect.y, span->left - cursor, rect.height});
                cursor = std::min(right, std::max(cursor, span->right));
            }
            if (cursor < right)
                text_rectangles.push_back({cursor, rect.y, right - cursor, rect.height});
        }
        for (const auto &span : break_spans)
            text_rectangles.push_back(span.marker);
        rectangles = std::move(text_rectangles);
    }

    // Glyph ascenders/descenders exclude the row's leading. Selection backgrounds
    // cover the logical row instead, so adjacent lines share the same boundary.
    // Keep fractional layout coordinates: independent rounding or overlapping
    // rectangles would introduce seams or double-blended selection colors.
    struct SelectionRow {
        float glyph_top;
        float top;
        float height;
    };
    std::vector<SelectionRow> selection_rows;
    const int32_t line_count = skb_layout_get_lines_count(layout->layout.get());
    const int32_t row_start = std::max(0, std::min(first_line, last_line));
    const int32_t row_end = std::min(line_count, std::max(first_line, last_line) + 1);
    selection_rows.reserve(row_end - row_start);
    for (int32_t index = row_start; index < row_end; ++index) {
        const auto line = skb_layout_get_line_at(layout->layout.get(), index);
        selection_rows.push_back({line.baseline + line.ascender,
                                  line.bounds.y, line.bounds.height});
    }
    std::sort(selection_rows.begin(), selection_rows.end(),
        [](const SelectionRow &a, const SelectionRow &b) { return a.glyph_top < b.glyph_top; });
    constexpr float row_epsilon = 0.01f;
    for (auto &rect : rectangles) {
        const auto row = std::lower_bound(selection_rows.begin(), selection_rows.end(),
            rect.y - row_epsilon,
            [](const SelectionRow &item, float top) { return item.glyph_top < top; });
        if (row != selection_rows.end() && std::abs(row->glyph_top - rect.y) <= row_epsilon) {
            rect.y = row->top;
            rect.height = row->height;
        }
    }

    // Visual runs in mixed-direction text may produce touching or overlapping
    // bounds on the same line. Returning those independently causes translucent
    // selection colors to be composited more than once at run boundaries.
    std::sort(rectangles.begin(), rectangles.end(),
              [](const TextRect &left, const TextRect &right) {
                  if (left.y != right.y)
                      return left.y < right.y;
                  return left.x < right.x;
              });
    std::vector<TextRect> normalized;
    constexpr float epsilon = 0.01f;
    for (const TextRect &rect : rectangles) {
        if (!std::isfinite(rect.x) || !std::isfinite(rect.y) || !std::isfinite(rect.width) ||
            !std::isfinite(rect.height) || rect.width <= 0.0f || rect.height <= 0.0f)
            continue;
        if (!normalized.empty()) {
            TextRect &previous = normalized.back();
            const bool same_line = std::abs(previous.y - rect.y) <= epsilon &&
                                   std::abs(previous.height - rect.height) <= epsilon;
            const float previous_right = previous.x + previous.width;
            if (same_line && rect.x <= previous_right + epsilon) {
                previous.width = std::max(previous_right, rect.x + rect.width) - previous.x;
                continue;
            }
        }
        normalized.push_back(rect);
    }
    constexpr std::size_t maximum_cached_selection_rectangles = 256;
    if (normalized.size() <= maximum_cached_selection_rectangles) {
        state_->selection_layout_id = state_->active_layout_id;
        state_->selection_layout_generation = generation;
        state_->selection_start = start;
        state_->selection_end = end;
        state_->selection_rectangles = normalized;
    } else {
        state_->selection_layout_id = 0;
        state_->selection_rectangles.clear();
    }
    return normalized;
}

uint64_t TextEngine::font_collection_generation() const {
    return state_->font_collection ? state_->font_collection->generation() : 0;
}

uint64_t TextEngine::layout_generation() const {
    const auto *layout = active_layout(*state_);
    return layout ? skb_layout_get_generation(layout->layout.get()) : 0;
}

TextLayoutId TextEngine::active_layout_id() const {
    return active_layout(*state_) ? state_->active_layout_id : 0;
}

uint32_t TextEngine::layout_build_count() const {
    return state_->layout_builds;
}

uint32_t TextEngine::atlas_texture_count() const {
    return state_->atlas ? static_cast<uint32_t>(skb_image_atlas_get_texture_count(state_->atlas))
                         : 0;
}

uint32_t TextEngine::scale_generation() const {
    return state_->scale_generation;
}

TextEngineStats TextEngine::stats() const {
    if (!state_->atlas)
        return {};
    const auto scratch = skb_temp_alloc_stats(state_->temporary);
    const skb_image_atlas_stats_t atlas_stats = skb_image_atlas_get_stats(state_->atlas);
    TextEngineStats result{};
    result.scratch_allocated_bytes = scratch.allocated;
    result.scratch_used_bytes = scratch.used;
    result.glyph_cache_misses = atlas_stats.glyph_cache_misses;
    result.glyphs_rasterized = atlas_stats.glyphs_rasterized;
    result.prepared_batch_count = state_->prepared_batch_count;
    result.text_layout_cache_hits = state_->layout_cache_hits;
    result.text_layout_cache_misses = state_->layout_cache_misses;
    result.incremental_ascii_edits = state_->incremental_ascii_edits;
    result.edit_layout_fallbacks = state_->edit_layout_fallbacks;
    result.atlas_pages = atlas_texture_count();
    result.scale_generation = state_->scale_generation;
    for (const auto &upload : atlas_uploads(true))
        result.atlas_bytes += static_cast<uint64_t>(upload.texture_width) * upload.texture_height *
                              upload.bytes_per_pixel;
    return result;
}

std::vector<AtlasUpload> TextEngine::pending_atlas_uploads() const {
    return atlas_uploads(false);
}

uint64_t TextEngine::atlas_generation_key() const {
    uint64_t key = 0;
    if (!state_->atlas)
        return key;
    const int count = skb_image_atlas_get_texture_count(state_->atlas);
    for (int index = 0; index < count; ++index) {
        key = key * UINT64_C(1099511628211) ^
              skb_image_atlas_get_texture_user_data(state_->atlas, index);
        key = key * UINT64_C(1099511628211) ^
              skb_image_atlas_get_texture_generation(state_->atlas, index);
    }
    return key;
}

bool TextEngine::prepare_glyph_atlas(TextLayoutId id, int32_t line_index, float pixel_scale,
                                     GlyphMode mode) {
    const auto *layout = find_layout(*state_, id);
    const auto raster_scale = text_raster_scale(pixel_scale);
    if (!layout || !raster_scale.key || line_index < -1 ||
        (line_index >= 0 && static_cast<std::size_t>(line_index) >= layout->result.lines.size()))
        return false;
    TextScratchScope scratch(state_->temporary);
    const skb_range_t lines = line_index < 0
        ? skb_range_t{0, skb_layout_get_lines_count(layout->layout.get())}
        : skb_range_t{line_index, line_index + 1};
    return skb_layout_prepare_glyphs_range(layout->layout.get(), lines, state_->atlas,
                                          state_->temporary, state_->rasterizer, raster_scale.value,
                                          raster_mode(mode));
}

std::vector<AtlasUpload> TextEngine::atlas_uploads(bool include_clean) const {
    std::vector<AtlasUpload> uploads;
    if (!state_->atlas)
        return uploads;
    const int count = skb_image_atlas_get_texture_count(state_->atlas);
    for (int index = 0; index < count; ++index) {
        const auto snapshot = skb_image_atlas_peek_texture_dirty(state_->atlas, index);
        const skb_rect2i_t dirty = snapshot.dirty;
        const bool is_dirty = !skb_rect2i_is_empty(dirty);
        if (!is_dirty && !include_clean)
            continue;
        const AtlasTextureId texture{
            static_cast<uint32_t>(skb_image_atlas_get_texture_user_data(state_->atlas, index))};
        if (!snapshot.pixels || !texture.value)
            continue;
        const uint8_t bytes_per_pixel =
            snapshot.format == SKB_IMAGE_ATLAS_FORMAT_RGBA8_PREMULTIPLIED ? 4 : 1;
        uploads.push_back({texture, static_cast<uint8_t>(index), atlas_format(snapshot.format),
                           bytes_per_pixel, snapshot.width, snapshot.height, snapshot.stride_bytes,
                           is_dirty ? dirty.x : 0, is_dirty ? dirty.y : 0,
                           is_dirty ? dirty.width : snapshot.width,
                           is_dirty ? dirty.height : snapshot.height, snapshot.pixels, is_dirty,
                           snapshot.texture_generation, snapshot.epoch});
    }
    return uploads;
}

bool TextEngine::acknowledge_atlas_upload(AtlasTextureId texture, uint64_t dirty_epoch) {
    if (!state_->atlas || !texture.value || !dirty_epoch)
        return false;
    const int count = skb_image_atlas_get_texture_count(state_->atlas);
    for (int index = 0; index < count; ++index) {
        if (skb_image_atlas_get_texture_user_data(state_->atlas, index) != texture.value)
            continue;
        return skb_image_atlas_ack_texture_dirty(state_->atlas, index, dirty_epoch);
    }
    return false;
}

} // namespace nkui
