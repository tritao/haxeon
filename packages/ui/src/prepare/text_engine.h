#ifndef NATIVEKIT_UI_TEXT_ENGINE_H
#define NATIVEKIT_UI_TEXT_ENGINE_H

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>
#include <utility>

#include "layout/layout_types.h"
#include "atlas_texture_id.h"

namespace nkui {

/** PreparedAtlas requires a matching prepare_glyph_atlas call before publication. */
enum class GlyphPreparation { Rasterize, PreparedAtlas };

enum class GlyphMode : uint8_t {
    Alpha = 1,
    Sdf,
    Color,
};

enum class AtlasTextureFormat : uint8_t {
    R8Mask = 0,
    R8Sdf,
    Rgba8Premultiplied,
};

struct TextLayoutOptions {
    float font_size = 16.0f;
    float letter_spacing = 0.0f;
    float line_height = 0.0f;
    uint32_t tab_width = 0;
    FontFamily family = FontFamily::Default;
    TextWrapMode wrap = TextWrapMode::WordCharacter;
    TextAlignment alignment = TextAlignment::Start;
    TextDirection direction = TextDirection::Auto;
};

struct GlyphVertex {
    float x;
    float y;
    float u;
    float v;
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t alpha;
};

struct GlyphBatch {
    AtlasTextureId atlas;
    uint32_t atlas_generation = 0;
    GlyphMode mode = GlyphMode::Alpha;
    uint32_t first_vertex = 0;
    uint32_t vertex_count = 0;
    uint32_t first_index = 0;
    uint32_t index_count = 0;
};

/** Logical codepoint cluster represented by one rendered quad. */
struct GlyphSourceRange {
    uint32_t first_vertex = 0;
    uint32_t vertex_count = 0;
    int32_t start = 0;
    int32_t end = 0;
};

struct PreparedGlyphs {
    // Positions and origins are in layout units; UVs address atlas texels.
    // pixel_scale is the canonical rasterization scale, not a baked transform.
    std::vector<GlyphVertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<GlyphBatch> batches;
    std::vector<GlyphSourceRange> source_ranges;
    float origin_x = 0.0f;
    float origin_y = 0.0f;
    float pixel_scale = 1.0f;
    GlyphMode mode = GlyphMode::Alpha;
    TextLayoutId layout_id = 0;
    uint64_t layout_generation = 0;
    uint64_t line_revision = 0;
    uint64_t publication_key = 0;
    int32_t source_start = -1;
    int32_t first_line = -1;
    int32_t end_line = -1;
};

/** Opaque white is the default foreground color. */
struct GlyphTint {
    uint8_t red = 255;
    uint8_t green = 255;
    uint8_t blue = 255;
    uint8_t alpha = 255;
};

/** Sorted, disjoint half-open codepoint ranges; clusters use their first codepoint. */
struct GlyphColorRange {
    int32_t start = 0;
    int32_t end = 0;
    GlyphTint tint{};
};

bool valid_glyph_color_ranges(const std::vector<GlyphColorRange> &ranges);
/** Recolors geometry in place without shaping or rasterization. */
void apply_glyph_colors(PreparedGlyphs &glyphs, GlyphTint base,
                        const std::vector<GlyphColorRange> &ranges);

struct TextPosition {
    int32_t offset = 0;
    uint8_t affinity = 0;
};

struct TextRange {
    int32_t start = 0;
    int32_t end = 0;
};

struct TextCaret {
    float x = 0.0f;
    float y = 0.0f;
    float ascender = 0.0f;
    float descender = 0.0f;
    float slope = 0.0f;
    uint8_t direction = 0;
};

struct TextRect {
    float x = 0.0f;
    float y = 0.0f;
    float width = 0.0f;
    float height = 0.0f;
};

struct TextIntrinsicMetrics {
    TextRect bounds{};
    /** Final insertion x, including trailing whitespace (single-line measurements). */
    float advance_x = 0.0f;
    float baseline = 0.0f;
    bool has_baseline = false;
};

struct TextLayoutLine {
    std::size_t text_offset = 0;
    std::size_t text_length = 0;
    TextRect bounds{};
};

struct TextLayoutResult {
    TextLayoutId id = 0;
    TextRect bounds{};
    std::vector<TextLayoutLine> lines;
};

struct AtlasUpload {
    AtlasTextureId texture;
    uint8_t texture_index = 0;
    AtlasTextureFormat format = AtlasTextureFormat::R8Mask;
    uint8_t bytes_per_pixel = 0;
    int32_t texture_width = 0;
    int32_t texture_height = 0;
    int32_t row_pitch = 0;
    int32_t x = 0;
    int32_t y = 0;
    int32_t width = 0;
    int32_t height = 0;
    const uint8_t *pixels = nullptr;
    bool dirty = false;
    uint32_t generation = 0;
    uint64_t dirty_epoch = 0;
    // Tracks source lifetime for renderer cache retirement; pixels remain engine-owned.
    std::shared_ptr<const void> owner;
};

struct TextEngineStats {
    uint64_t scratch_allocated_bytes = 0;
    uint64_t scratch_used_bytes = 0;
    uint64_t glyph_cache_misses = 0;
    uint64_t glyphs_rasterized = 0;
    uint64_t prepared_batch_count = 0;
    uint64_t text_layout_cache_hits = 0;
    uint64_t text_layout_cache_misses = 0;
    uint64_t incremental_ascii_edits = 0;
    uint64_t edit_layout_fallbacks = 0;
    uint64_t atlas_pages = 0;
    uint64_t atlas_bytes = 0;
    uint32_t scale_generation = 0;
};

class FontCollection {
  public:
    FontCollection();
    ~FontCollection();
    FontCollection(const FontCollection &) = delete;
    FontCollection &operator=(const FontCollection &) = delete;

    bool valid() const;
    bool add_font(const char *path, FontFamily family = FontFamily::Default);
    bool add_font_from_shared_data(const char *name,
                                   const std::shared_ptr<std::vector<uint8_t>> &data,
                                   FontFamily family = FontFamily::Default);
    bool add_system_fallbacks();
    uint64_t generation() const;
    uint32_t font_load_count() const;

  private:
    struct State;
    State *state_ = nullptr;
    friend class TextEngine;
};

class TextEngine {
  public:
    TextEngine();
    explicit TextEngine(std::shared_ptr<FontCollection> fonts);
    ~TextEngine();
    TextEngine(const TextEngine &) = delete;
    TextEngine &operator=(const TextEngine &) = delete;

    bool valid() const;
    bool resource_limited() const;
    /** Changes when atlas pages are created or their glyph coordinates change. */
    uint64_t atlas_generation_key() const;
    /** Rasterize a layout, or one line, without publishing geometry or UVs. */
    bool prepare_glyph_atlas(TextLayoutId id, int32_t line_index, float pixel_scale, GlyphMode mode);
    bool add_font(const char *path, FontFamily family = FontFamily::Default);
    bool add_font_from_data(const char *name, const void *data, std::size_t bytes,
                            FontFamily family = FontFamily::Default);
    bool add_font_from_shared_data(const char *name,
                                   const std::shared_ptr<std::vector<uint8_t>> &data,
                                   FontFamily family = FontFamily::Default);
    bool add_system_fallbacks();
    bool measure_intrinsic_utf8(const char *text, const TextLayoutOptions &options,
                                TextIntrinsicMetrics *result);
    bool layout_utf8(const char *text, float width, float font_size);
    bool layout_utf8(const char *text, float width, const TextLayoutOptions &options);
    bool layout_utf8(const char *text, float width, const TextLayoutOptions &options,
                     TextLayoutResult *result);
    /** Replaces a codepoint range in the active layout, retaining its style and width. */
    bool edit_utf8(int32_t start, int32_t end, const char *replacement,
                   TextLayoutResult *result);
    void prune_layout_cache(const std::vector<TextLayoutId> &retained_ids, std::size_t max_entries);
    bool has_layout(TextLayoutId id) const;
    bool prepare_glyphs(float origin_x, float origin_y, float pixel_scale, GlyphMode mode,
                        PreparedGlyphs &output);
    /** Conservative visual-line range intersecting local vertical bounds. */
    std::pair<uint32_t, uint32_t> visible_lines(float min_y, float max_y) const;
    TextRect line_bounds(uint32_t index) const;
    /** Logical line rectangles intersecting a codepoint and vertical range. */
    std::vector<TextRect> line_rects(int32_t start, int32_t end, float min_y,
                                     float max_y) const;
    bool prepare_glyphs_for_lines(uint32_t first, uint32_t end, float origin_x, float origin_y,
                                  float pixel_scale, GlyphMode mode, PreparedGlyphs &output);
    std::shared_ptr<const PreparedGlyphs> published_glyphs_for_lines(
        TextLayoutId id, uint32_t first, uint32_t end, float origin_x, float origin_y,
        float pixel_scale, GlyphMode mode, GlyphTint tint = {},
        const std::vector<GlyphColorRange> &ranges = {});
    bool prepare_glyphs_for_line(uint32_t line_index, float origin_x, float origin_y,
                                 float pixel_scale, GlyphMode mode, PreparedGlyphs &output);
    bool prepare_glyphs_for_line(TextLayoutId id, uint32_t line_index, float origin_x,
                                 float origin_y, float pixel_scale, GlyphMode mode,
                                 PreparedGlyphs &output,
                                 GlyphPreparation preparation = GlyphPreparation::Rasterize);
    /**
     * Returns an immutable glyph snapshot for one layout or one of its lines.
     *
     * Snapshots are shared: repeated requests with the same layout or row revision,
     * geometry, scale, mode and colors return the same object, and a snapshot stays
     * valid after later preparation passes. That makes them safe to bind into an
     * owned resource set that outlives the frame that produced it, without
     * copying glyph buffers. Returns null for an unknown layout, an out-of-range
     * line, or a non-positive scale.
     */
    std::shared_ptr<const PreparedGlyphs> published_glyphs(TextLayoutId id, float origin_x,
                                                           float origin_y, float pixel_scale,
                                                           GlyphMode mode, GlyphTint tint = {},
                                                           const std::vector<GlyphColorRange> &ranges = {},
                                                           GlyphPreparation preparation = GlyphPreparation::Rasterize);
    std::shared_ptr<const PreparedGlyphs>
    published_glyphs_for_line(TextLayoutId id, uint32_t line_index, float origin_x, float origin_y,
                              float pixel_scale, GlyphMode mode, GlyphTint tint = {},
                              const std::vector<GlyphColorRange> &ranges = {},
                              GlyphPreparation preparation = GlyphPreparation::Rasterize);
    bool prepared_glyphs_current(const PreparedGlyphs &glyphs) const;
    int32_t text_count() const;
    TextRect bounds() const;
    TextPosition hit_test(float x, float y) const;
    int32_t offset_from_position(TextPosition position) const;
    TextCaret caret(TextPosition position) const;
    TextPosition word_start(TextPosition position) const;
    TextPosition word_end(TextPosition position) const;
    int32_t next_grapheme(int32_t offset) const;
    int32_t previous_grapheme(int32_t offset) const;
    int32_t align_grapheme(int32_t offset) const;
    TextRange word_range_at(int32_t offset) const;
    TextRange line_range_at(int32_t offset) const;
    int32_t move_word(int32_t offset, int32_t direction, bool mac_style) const;
    int32_t move_paragraph(int32_t offset, int32_t direction, bool mac_style) const;
    std::vector<TextRect> selection_rects(TextPosition start, TextPosition end) const;
    uint64_t font_collection_generation() const;
    uint64_t layout_generation() const;
    /** Identifier of the layout that prepare_glyphs() prepares; zero when none is active. */
    TextLayoutId active_layout_id() const;
    uint32_t layout_build_count() const;
    uint32_t atlas_texture_count() const;
    uint32_t scale_generation() const;
    TextEngineStats stats() const;
    std::vector<AtlasUpload> pending_atlas_uploads() const;
    std::vector<AtlasUpload> atlas_uploads(bool include_clean) const;
    bool acknowledge_atlas_upload(AtlasTextureId texture, uint64_t dirty_epoch);

    struct State;

  private:
    std::shared_ptr<const PreparedGlyphs> publish_glyphs(TextLayoutId id, int32_t line_index,
                                                         float origin_x, float origin_y,
                                                         float pixel_scale, GlyphMode mode,
                                                         GlyphTint tint,
                                                         const std::vector<GlyphColorRange> &ranges, int32_t end_line = -1,
                                                         GlyphPreparation preparation = GlyphPreparation::Rasterize);
    bool prepare_glyphs_internal(TextLayoutId id, float origin_x, float origin_y, float pixel_scale,
                                 GlyphMode mode, PreparedGlyphs &output, int32_t line_start,
                                 int32_t line_end, float line_x, float line_y, int32_t line_index = -1, int32_t end_line = -1,
                                 GlyphPreparation preparation = GlyphPreparation::Rasterize);

    State *state_ = nullptr;
};

} // namespace nkui

#endif
