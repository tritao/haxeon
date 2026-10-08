#include "prepare/text_engine.h"

#include <cstring>
#include <cmath>
#include <string>
#include <vector>

#ifndef NKUI_TEST_FONT_PATH
#error NKUI_TEST_FONT_PATH is required
#endif
#ifndef NKUI_TEST_COLOR_FONT_PATH
#error NKUI_TEST_COLOR_FONT_PATH is required
#endif

using namespace nkui;

int main() {
    auto shared_fonts = std::make_shared<FontCollection>();
    if (!shared_fonts->valid() || !shared_fonts->add_font(NKUI_TEST_FONT_PATH) ||
        shared_fonts->font_load_count() != 1)
        return 48;
    // Scratch is reusable and does not become part of retained layout ownership.
    {
        TextEngine scratch(shared_fonts);
        TextLayoutResult previous;
        if (!scratch.layout_utf8("retained before scratch reuse", 200.0f,
                                 TextLayoutOptions{}, &previous)) return 182;
        for (int i = 0; i < 200; ++i) {
            TextLayoutResult current;
            const std::string text = "changed scratch " + std::to_string(i);
            if (!scratch.layout_utf8(text.c_str(), 200.0f, TextLayoutOptions{}, &current)) return 183;
            scratch.prune_layout_cache({previous.id, current.id}, 2);
            PreparedGlyphs glyphs;
            if (!scratch.prepare_glyphs_for_line(previous.id, 0, 0.0f, 0.0f,
                                                1.0f, GlyphMode::Alpha, glyphs) ||
                glyphs.vertices.empty()) return 184;
            TextIntrinsicMetrics measured;
            if (!scratch.measure_intrinsic_utf8(text.c_str(), TextLayoutOptions{}, &measured)) return 185;
            const auto stats = scratch.stats();
            if (stats.scratch_used_bytes != 0 || stats.scratch_allocated_bytes > 128 * 1024) return 186;
            if (stats.atlas_bytes > 256 * 256 * 4) return 187;
        }
    }
    // Buffer-size and buffer-fill queries repeat the same selection. Cached
    // geometry must remain value-owned and agree with a fresh layout after
    // edits, endpoint/affinity changes, wrapping and font-size changes.
    {
        TextEngine cached(shared_fonts);
        std::string text(1024, 'a');
        TextLayoutOptions options;
        options.font_size = 15.0f;
        float width = 128.0f;
        const auto equal = [](const std::vector<TextRect> &a, const std::vector<TextRect> &b) {
            if (a.size() != b.size()) return false;
            for (std::size_t index = 0; index < a.size(); ++index)
                if (a[index].x != b[index].x || a[index].y != b[index].y ||
                    a[index].width != b[index].width || a[index].height != b[index].height)
                    return false;
            return true;
        };
        const auto verify = [&]() {
            TextEngine fresh(shared_fonts);
            if (!fresh.layout_utf8(text.c_str(), width, options)) return false;
            for (const auto endpoints : {std::pair{TextPosition{0, 0}, TextPosition{80, 0}},
                    std::pair{TextPosition{0, 0}, TextPosition{81, 0}},
                    std::pair{TextPosition{80, 0}, TextPosition{0, 0}},
                    std::pair{TextPosition{0, 2}, TextPosition{80, 2}},
                    std::pair{TextPosition{0, 0}, TextPosition{80, 0}}}) {
                const auto expected = fresh.selection_rects(endpoints.first, endpoints.second);
                auto actual = cached.selection_rects(endpoints.first, endpoints.second);
                if (!equal(actual, expected)) return false;
                if (!actual.empty()) actual.front().x += 100.0f;
                if (!equal(cached.selection_rects(endpoints.first, endpoints.second), expected)) return false;
            }
            return true;
        };
        if (!cached.layout_utf8(text.c_str(), width, options) || !verify()) return 190;
        text[32] = 'w';
        if (!cached.edit_utf8(32, 33, "w", nullptr) ||
            cached.stats().incremental_ascii_edits != 1 || !verify()) return 191;
        text.replace(32, 1, "é");
        if (!cached.edit_utf8(32, 33, "é", nullptr) || !verify()) return 192;
        width = 64.0f;
        if (!cached.layout_utf8(text.c_str(), width, options) || !verify()) return 193;
        options.font_size = 22.0f;
        if (!cached.layout_utf8(text.c_str(), width, options) || !verify()) return 194;
        text = "abc אבג 🙂 é xyz\nsecond line with mixed text " + text;
        if (!cached.layout_utf8(text.c_str(), width, options) || !verify()) return 195;
        // Large selections bypass retention but still return complete geometry.
        text = std::string(4096, 'a');
        if (!cached.layout_utf8(text.c_str(), 16.0f, options)) return 196;
        const auto large = cached.selection_rects({0, 0}, {4096, 0});
        if (large.size() <= 256 || !equal(large, cached.selection_rects({0, 0}, {4096, 0}))) return 197;
    }
    TextEngine empty_hit_test(shared_fonts);
    for (const char *text : {"", "\n", "abc\n", "abc\n\n"}) {
        if (!empty_hit_test.layout_utf8("previous content", 200.0f, 16.0f) ||
            !empty_hit_test.layout_utf8(text, 200.0f, 16.0f))
            return 180;
        const auto last = empty_hit_test.caret({empty_hit_test.text_count(), 0});
        for (float x : {-100.0f, 0.0f, 100.0f}) {
            const auto hit = empty_hit_test.hit_test(x, last.y);
            if (empty_hit_test.offset_from_position(hit) != empty_hit_test.text_count())
                return 181;
        }
    }
    TextEngine shared_first(shared_fonts);
    TextEngine shared_second(shared_fonts);
    if (!shared_first.layout_utf8("first", 200.0f, 16.0f) ||
        !shared_second.layout_utf8("second", 200.0f, 16.0f) ||
        shared_fonts->font_load_count() != 1 ||
        shared_first.font_collection_generation() != shared_second.font_collection_generation())
        return 49;
    PreparedGlyphs shared_glyphs;
    if (!shared_first.prepare_glyphs(0.0f, 0.0f, 1.0f, GlyphMode::Alpha, shared_glyphs) ||
        shared_glyphs.vertices.empty())
        return 50;

    // Edit offsets are codepoints, including when the replaced UTF-8 spans
    // multiple bytes. The result must share fresh-layout caret geometry.
    {
        TextEngine edited(shared_fonts);
        TextEngine fresh(shared_fonts);
        if (!edited.layout_utf8("aé🙂b", 80.0f, 16.0f))
            return 103;
        const auto matches_fresh = [&](const char *value, int32_t count) {
            if (!fresh.layout_utf8(value, 80.0f, 16.0f) || edited.text_count() != count ||
                edited.bounds().height != fresh.bounds().height)
                return false;
            for (int32_t offset = 0; offset <= count; ++offset) {
                const auto actual = edited.caret({offset, 0});
                const auto expected = fresh.caret({offset, 0});
                if (actual.x != expected.x || actual.y != expected.y)
                    return false;
            }
            return true;
        };
        if (!edited.edit_utf8(1, 3, "z", nullptr) || !matches_fresh("azb", 3) ||
            !edited.edit_utf8(2, 2, "🙂", nullptr) || !matches_fresh("az🙂b", 4) ||
            !edited.edit_utf8(2, 3, "", nullptr) || !matches_fresh("azb", 3))
            return 104;
        if (edited.stats().incremental_ascii_edits != 0 ||
            edited.stats().edit_layout_fallbacks != 3)
            return 112;
        const auto stable = edited.active_layout_id();
        if (edited.edit_utf8(4, 5, "x", nullptr) || edited.active_layout_id() != stable ||
            !matches_fresh("azb", 3))
            return 105;
    }
    {
        TextEngine edited(shared_fonts);
        TextEngine fresh(shared_fonts);
        TextLayoutOptions options;
        options.font_size = 15.0f;
        std::string text(4096, 'a');
        TextLayoutResult current, expected;
        if (!edited.layout_utf8(text.c_str(), 200.0f, options, &current))
            return 106;
        text.insert(2048, 1, 'b');
        if (!edited.edit_utf8(2048, 2048, "b", &current) ||
            !fresh.layout_utf8(text.c_str(), 200.0f, options, &expected) ||
            edited.stats().incremental_ascii_edits != 1 ||
            edited.stats().edit_layout_fallbacks != 0 ||
            current.lines.size() != expected.lines.size())
            return 107;
        for (std::size_t index = 0; index < current.lines.size(); ++index)
            if (current.lines[index].text_offset != expected.lines[index].text_offset ||
                current.lines[index].text_length != expected.lines[index].text_length ||
                current.lines[index].bounds.y != expected.lines[index].bounds.y)
                return 108;
        for (int offset = 2046; offset <= 2051; ++offset) {
            const auto actual = edited.caret({offset, 0});
            const auto oracle = fresh.caret({offset, 0});
            if (actual.x != oracle.x || actual.y != oracle.y)
                return 109;
        }
        const auto visible = edited.visible_lines(0.0f, 200.0f);
        const auto oracle_visible = fresh.visible_lines(0.0f, 200.0f);
        if (visible != oracle_visible)
            return 110;
        const auto rows = edited.line_rects(2040, 2070, 0.0f, 10000.0f);
        const auto oracle_rows = fresh.line_rects(2040, 2070, 0.0f, 10000.0f);
        if (rows.size() != oracle_rows.size() || rows.empty())
            return 113;
        for (std::size_t index = 0; index < rows.size(); ++index)
            if (rows[index].x != oracle_rows[index].x ||
                rows[index].y != oracle_rows[index].y ||
                rows[index].width != oracle_rows[index].width ||
                rows[index].height != oracle_rows[index].height)
                return 114;
        text.erase(2048, 1);
        if (!edited.edit_utf8(2048, 2049, "", &current) ||
            !fresh.layout_utf8(text.c_str(), 200.0f, options, &expected) ||
            edited.stats().incremental_ascii_edits != 2 ||
            current.lines.size() != expected.lines.size())
            return 111;
    }

    // A same-advance guarded edit may retain all wrapped row geometry. Check
    // the retained layout against a freshly built generation, including the
    // changed row's glyph-dependent bounds and caret positions.
    {
        TextEngine retained(shared_fonts);
        TextEngine fresh(shared_fonts);
        TextLayoutOptions options;
        options.font_size = 15.0f;
        std::string text(4096, 'a');
        TextLayoutResult actual, oracle;
        if (!retained.layout_utf8(text.c_str(), 200.0f, options, &actual) ||
            !retained.edit_utf8(2048, 2049, "a", &actual) ||
            !fresh.layout_utf8(text.c_str(), 200.0f, options, &oracle) ||
            retained.stats().incremental_ascii_edits != 1 ||
            actual.lines.size() != oracle.lines.size())
            return 131;
        for (std::size_t row = 0; row < actual.lines.size(); ++row)
            if (actual.lines[row].text_offset != oracle.lines[row].text_offset ||
                actual.lines[row].text_length != oracle.lines[row].text_length ||
                actual.lines[row].bounds.x != oracle.lines[row].bounds.x ||
                actual.lines[row].bounds.y != oracle.lines[row].bounds.y ||
                actual.lines[row].bounds.width != oracle.lines[row].bounds.width ||
                actual.lines[row].bounds.height != oracle.lines[row].bounds.height)
                return 132;
        for (int32_t offset : {0, 2047, 2048, 2049, 4096}) {
            const auto a = retained.caret({offset, 0});
            const auto b = fresh.caret({offset, 0});
            if (a.x != b.x || a.y != b.y)
                return 133;
        }
    }
    {
        auto mono_fonts = std::make_shared<FontCollection>();
        if (!mono_fonts->valid() || !mono_fonts->add_font(NKUI_TEST_MONO_FONT_PATH))
            return 134;
        TextEngine retained(mono_fonts);
        TextEngine fresh(mono_fonts);
        TextLayoutOptions options;
        options.font_size = 15.0f;
        std::string text(4096, 'a');
        TextLayoutResult actual, oracle;
        if (!retained.layout_utf8(text.c_str(), 200.0f, options, &actual))
            return 135;
        const auto matches_fresh = [&]() {
            if (!fresh.layout_utf8(text.c_str(), 200.0f, options, &oracle) ||
                actual.lines.size() != oracle.lines.size() ||
                actual.bounds.height != oracle.bounds.height)
                return false;
            for (std::size_t row = 0; row < actual.lines.size(); ++row)
                if (actual.lines[row].text_offset != oracle.lines[row].text_offset ||
                    actual.lines[row].text_length != oracle.lines[row].text_length ||
                    actual.lines[row].bounds.x != oracle.lines[row].bounds.x ||
                    actual.lines[row].bounds.y != oracle.lines[row].bounds.y ||
                    actual.lines[row].bounds.width != oracle.lines[row].bounds.width ||
                    actual.lines[row].bounds.height != oracle.lines[row].bounds.height)
                    return false;
            for (int32_t offset : {0, 2047, 2048, 2049, static_cast<int32_t>(text.size())}) {
                const auto a = retained.caret({offset, 0});
                const auto b = fresh.caret({offset, 0});
                if (a.x != b.x || a.y != b.y)
                    return false;
            }
            for (float top : {0.0f, 800.0f, 1800.0f})
                if (retained.visible_lines(top, top + 100.0f) !=
                    fresh.visible_lines(top, top + 100.0f))
                    return false;
            return true;
        };
        text.insert(2048, 1, 'b');
        if (!retained.edit_utf8(2048, 2048, "b", &actual) || !matches_fresh())
            return 136;
        text.erase(2048, 1);
        if (!retained.edit_utf8(2048, 2049, "", &actual) || !matches_fresh() ||
            retained.stats().incremental_ascii_edits != 2)
            return 137;
    }

    // An unsupported character must not move its insertion caret to the line origin.
    TextEngine unsupported(shared_fonts);
    if (!unsupported.layout_utf8("abc🙂def", 200.0f, 16.0f))
        return 101;
    const auto before_missing = unsupported.caret({2, 0});
    const auto at_missing = unsupported.caret({3, 0});
    const auto after_missing = unsupported.caret({4, 0});
    if (before_missing.x <= 0 || at_missing.x < before_missing.x || at_missing.x > after_missing.x)
        return 102;

    // Intrinsic measurements are cached by text and style, and a cached answer equals a fresh one.
    {
        TextEngine measured(shared_fonts);
        TextLayoutOptions small_options, large_options;
        small_options.font_size = 14.0f;
        large_options.font_size = 28.0f;
        TextIntrinsicMetrics first, again, large, other_text;
        if (!measured.measure_intrinsic_utf8("measure me", small_options, &first) ||
            !measured.measure_intrinsic_utf8("measure me", small_options, &again) ||
            first.bounds.width <= 0.0f || again.bounds.width != first.bounds.width ||
            again.bounds.height != first.bounds.height || again.baseline != first.baseline)
            return 90;
        if (!measured.measure_intrinsic_utf8("measure me", large_options, &large) ||
            large.bounds.width <= first.bounds.width)
            return 91;
        if (!measured.measure_intrinsic_utf8("measure me a little longer", small_options,
                                             &other_text) ||
            other_text.bounds.width <= first.bounds.width)
            return 92;
        TextEngine fresh(shared_fonts);
        TextIntrinsicMetrics independent;
        if (!fresh.measure_intrinsic_utf8("measure me", small_options, &independent) ||
            independent.bounds.width != first.bounds.width)
            return 93;
    }

    TextEngine engine;
    if (!engine.valid() || !engine.add_font(NKUI_TEST_FONT_PATH) ||
        !engine.add_font(NKUI_TEST_COLOR_FONT_PATH, FontFamily::Emoji) ||
        !engine.layout_utf8("áb NativeKit مرحبا", 500.0f, 28.0f))
        return 1;
    if (!engine.font_collection_generation() || !engine.layout_generation())
        return 2;
    if (engine.layout_build_count() != 1 ||
        !engine.layout_utf8("áb NativeKit مرحبا", 500.0f, 28.0f) ||
        engine.layout_build_count() != 1 || engine.bounds().width <= 0.0f)
        return 3;
    const int32_t next = engine.next_grapheme(0);
    if (next <= 1 || engine.previous_grapheme(next) != 0 || engine.align_grapheme(1) != 0)
        return 4;
    const TextPosition start{0, 1};
    const TextPosition end{next, 1};
    const auto caret = engine.caret(start);
    const auto hit = engine.hit_test(caret.x, caret.y);
    if (hit.offset < 0 || engine.selection_rects(start, end).empty())
        return 5;
    PreparedGlyphs glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.0f, GlyphMode::Alpha, glyphs))
        return 6;
    if (glyphs.vertices.empty() || glyphs.indices.empty() || glyphs.batches.empty() ||
        engine.atlas_texture_count() == 0)
        return 7;
    const auto initial_stats = engine.stats();
    if (!initial_stats.glyph_cache_misses || !initial_stats.glyphs_rasterized ||
        initial_stats.prepared_batch_count < glyphs.batches.size())
        return 8;
    for (const auto &batch : glyphs.batches)
        if (!batch.atlas.value || batch.mode != GlyphMode::Alpha || !batch.vertex_count ||
            !batch.index_count)
            return 9;
    const auto first_query = engine.pending_atlas_uploads();
    const auto second_query = engine.pending_atlas_uploads();
    if (first_query.empty() || first_query.size() != second_query.size())
        return 10;
    for (const auto &batch : glyphs.batches) {
        bool matched_generation = false;
        for (const auto &upload : first_query)
            matched_generation =
                matched_generation || (upload.texture.value == batch.atlas.value &&
                                       upload.generation == batch.atlas_generation);
        if (!matched_generation)
            return 11;
    }
    if (first_query.front().format != AtlasTextureFormat::R8Mask ||
        engine.acknowledge_atlas_upload(first_query.front().texture,
                                         first_query.front().dirty_epoch + 1) ||
        engine.pending_atlas_uploads().empty())
        return 12;
    for (const auto &upload : first_query)
        if (!upload.texture.value || !upload.pixels ||
            (upload.bytes_per_pixel != 1 && upload.bytes_per_pixel != 4) || upload.width <= 0 ||
            upload.height <= 0 || upload.row_pitch <= 0 || !upload.generation ||
            !upload.dirty_epoch ||
            !engine.acknowledge_atlas_upload(upload.texture, upload.dirty_epoch))
            return 13;
    if (!engine.pending_atlas_uploads().empty())
        return 14;
    const auto clean_uploads = engine.atlas_uploads(true);
    if (clean_uploads.size() != first_query.size())
        return 14;
    for (const auto &upload : clean_uploads)
        if (upload.dirty || upload.x != 0 || upload.y != 0 ||
            upload.width != upload.texture_width || upload.height != upload.texture_height)
            return 15;
    const uint64_t stable_layout_generation = engine.layout_generation();
    PreparedGlyphs fractional_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.25f, GlyphMode::Alpha, fractional_glyphs) ||
        engine.layout_generation() != stable_layout_generation)
        return 15;
    for (const auto &upload : engine.pending_atlas_uploads())
        if (!engine.acknowledge_atlas_upload(upload.texture, upload.dirty_epoch))
            return 16;
    const auto fractional_stats = engine.stats();
    PreparedGlyphs repeated_fractional_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.25f, GlyphMode::Alpha,
                                repeated_fractional_glyphs) ||
        !engine.pending_atlas_uploads().empty())
        return 17;
    const auto repeated_stats = engine.stats();
    if (repeated_stats.glyph_cache_misses != fractional_stats.glyph_cache_misses ||
        repeated_stats.glyphs_rasterized != fractional_stats.glyphs_rasterized ||
        repeated_stats.prepared_batch_count <= fractional_stats.prepared_batch_count)
        return 18;
    PreparedGlyphs native_scale_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.0f, GlyphMode::Alpha, native_scale_glyphs) ||
        !engine.pending_atlas_uploads().empty())
        return 19;
    PreparedGlyphs sdf_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.0f, GlyphMode::Sdf, sdf_glyphs) ||
        sdf_glyphs.batches.empty())
        return 20;
    const auto sdf_uploads = engine.pending_atlas_uploads();
    bool saw_sdf = false;
    for (const auto &upload : sdf_uploads) {
        saw_sdf = saw_sdf || upload.format == AtlasTextureFormat::R8Sdf;
        if (upload.format != AtlasTextureFormat::R8Sdf || upload.bytes_per_pixel != 1 ||
            !engine.acknowledge_atlas_upload(upload.texture, upload.dirty_epoch))
            return 21;
    }
    if (!saw_sdf || !engine.pending_atlas_uploads().empty())
        return 22;
    if (!engine.prepared_glyphs_current(glyphs))
        return 23;
    PreparedGlyphs stale_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.125f, GlyphMode::Alpha, stale_glyphs))
        return 24;
    const auto stale_uploads = engine.pending_atlas_uploads();
    if (stale_uploads.empty())
        return 25;
    PreparedGlyphs updated_glyphs;
    if (!engine.prepare_glyphs(10.0f, 40.0f, 1.375f, GlyphMode::Alpha, updated_glyphs))
        return 26;
    bool replaced_first_epoch = false;
    for (const auto &upload : engine.pending_atlas_uploads()) {
        for (const auto &stale : stale_uploads) {
            if (upload.texture.value == stale.texture.value &&
                upload.dirty_epoch != stale.dirty_epoch) {
                replaced_first_epoch = true;
                if (engine.acknowledge_atlas_upload(stale.texture, stale.dirty_epoch))
                    return 27;
            }
        }
        if (!engine.acknowledge_atlas_upload(upload.texture, upload.dirty_epoch))
            return 28;
    }
    if (!replaced_first_epoch || !engine.pending_atlas_uploads().empty())
        return 29;
    if (engine.layout_build_count() != 1 ||
        engine.layout_generation() != stable_layout_generation)
        return 30;

    if (!engine.layout_utf8("😀", 80.0f, 32.0f))
        return 31;
    PreparedGlyphs color_glyphs;
    if (!engine.prepare_glyphs(0.0f, 0.0f, 1.0f, GlyphMode::Color, color_glyphs) ||
        color_glyphs.batches.empty())
        return 31;
    bool saw_color = false;
    for (const auto &batch : color_glyphs.batches)
        saw_color = saw_color || batch.mode == GlyphMode::Color;
    for (const auto &upload : engine.pending_atlas_uploads()) {
        if (upload.format != AtlasTextureFormat::Rgba8Premultiplied || upload.bytes_per_pixel != 4)
            return 32;
        if (!engine.acknowledge_atlas_upload(upload.texture, upload.dirty_epoch))
            return 33;
    }
    if (!saw_color || !engine.pending_atlas_uploads().empty())
        return 34;

    const char *unicode_samples[] = {
        "שלום עולם", "नमस्ते दुनिया", "你好世界", "👩‍🚀", "क्‍ष", "office ﬁ á",
    };
    int sample_index = 0;
    for (const char *sample : unicode_samples) {
        if (!engine.layout_utf8(sample, 90.0f, 24.0f) || engine.bounds().width <= 0.0f)
            return 35;
        const int32_t end = engine.next_grapheme(0);
        if (end <= 0 || (sample_index != 4 && engine.selection_rects({0, 0}, {end, 0}).empty()))
            return 36;
        ++sample_index;
    }
    const char *mixed_selection = "こんにちは — שלום — NativeKit مرحبا";
    if (!engine.layout_utf8(mixed_selection, 500.0f, 24.0f))
        return 51;
    const auto mixed_rects = engine.selection_rects({0, 0}, {32, 0});
    if (mixed_rects.empty())
        return 51;
    for (std::size_t left = 0; left < mixed_rects.size(); ++left) {
        for (std::size_t right = left + 1; right < mixed_rects.size(); ++right) {
            const auto &a = mixed_rects[left];
            const auto &b = mixed_rects[right];
            const float overlap_width = std::min(a.x + a.width, b.x + b.width) - std::max(a.x, b.x);
            const float overlap_height =
                std::min(a.y + a.height, b.y + b.height) - std::max(a.y, b.y);
            if (overlap_width > 0.01f && overlap_height > 0.01f)
                return 52;
        }
    }
    TextLayoutOptions options;
    options.font_size = 24.0f;
    options.letter_spacing = 1.0f;
    options.line_height = 40.0f;
    options.wrap = TextWrapMode::None;
    if (!engine.layout_utf8("NativeKit text options", 500.0f, options) ||
        engine.bounds().height < 39.0f)
        return 37;
    const uint32_t options_builds = engine.layout_build_count();
    if (!engine.layout_utf8("NativeKit text options", 500.0f, options) ||
        engine.layout_build_count() != options_builds)
        return 38;
    TextLayoutOptions wrapped_options;
    wrapped_options.font_size = 24.0f;
    wrapped_options.wrap = TextWrapMode::WordCharacter;
    TextLayoutResult wrapped;
    if (!engine.layout_utf8("Skribidi owns paragraph wrapping in NativeKit", 90.0f,
                             wrapped_options, &wrapped) ||
        !wrapped.id || wrapped.lines.size() < 2)
        return 39;
    PreparedGlyphs first_line;
    PreparedGlyphs second_line;
    if (!engine.prepare_glyphs_for_line(0, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha, first_line) ||
        !engine.prepare_glyphs_for_line(1, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha, second_line) ||
        first_line.vertices.empty() || second_line.vertices.empty())
        return 40;

    TextLayoutOptions direction_options;
    direction_options.font_size = 24.0f;
    direction_options.wrap = TextWrapMode::None;
    TextLayoutResult automatic_direction;
    TextLayoutResult right_to_left_direction;
    TextLayoutResult automatic_direction_again;
    const uint32_t direction_builds = engine.layout_build_count();
    if (!engine.layout_utf8("NativeKit", 300.0f, direction_options, &automatic_direction))
        return 44;
    direction_options.direction = TextDirection::Rtl;
    if (!engine.layout_utf8("NativeKit", 300.0f, direction_options, &right_to_left_direction) ||
        automatic_direction.id == right_to_left_direction.id ||
        automatic_direction.lines.size() != 1 || right_to_left_direction.lines.size() != 1 ||
        right_to_left_direction.lines.front().bounds.x <=
            automatic_direction.lines.front().bounds.x + 1.0f ||
        engine.layout_build_count() != direction_builds + 2)
        return 45;
    direction_options.direction = TextDirection::Auto;
    if (!engine.layout_utf8("NativeKit", 300.0f, direction_options, &automatic_direction_again) ||
        automatic_direction_again.id != automatic_direction.id ||
        engine.layout_build_count() != direction_builds + 2)
        return 46;

    TextLayoutResult retained_first;
    TextLayoutResult retained_second;
    TextLayoutOptions retained_options;
    retained_options.font_size = 22.0f;
    retained_options.wrap = TextWrapMode::WordCharacter;
    if (!engine.layout_utf8("first retained paragraph", 120.0f, retained_options,
                             &retained_first) ||
        !engine.layout_utf8("second retained paragraph", 120.0f, retained_options,
                             &retained_second) ||
        !retained_first.id || !retained_second.id || retained_first.id == retained_second.id ||
        !engine.has_layout(retained_first.id) || !engine.has_layout(retained_second.id))
        return 42;
    const uint32_t retained_builds = engine.layout_build_count();
    PreparedGlyphs retained_first_glyphs;
    PreparedGlyphs retained_second_glyphs;
    if (!engine.prepare_glyphs_for_line(retained_first.id, 0, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha,
                                         retained_first_glyphs) ||
        !engine.prepare_glyphs_for_line(retained_second.id, 0, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha,
                                         retained_second_glyphs) ||
        retained_first_glyphs.layout_id != retained_first.id ||
        retained_second_glyphs.layout_id != retained_second.id ||
        engine.layout_build_count() != retained_builds)
        return 43;
    const std::vector<TextLayoutId> kept_layouts{retained_second.id};
    engine.prune_layout_cache(kept_layouts, 1);
    if (engine.has_layout(retained_first.id) || !engine.has_layout(retained_second.id))
        return 47;

    /*
     * Published snapshots are shared, immutable, and usable after later
     * preparation, which is what lets an owned resource set keep them without
     * copying glyph buffers.
     */
    TextLayoutResult published_layout{};
    TextLayoutOptions published_options;
    published_options.font_size = 16.0f;
    if (!engine.layout_utf8("published glyphs", 200.0f, published_options, &published_layout) ||
        !published_layout.id)
        return 51;
    const auto snapshot =
        engine.published_glyphs(published_layout.id, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha);
    if (!snapshot || snapshot->vertices.empty() || snapshot->indices.empty() ||
        snapshot->layout_id != published_layout.id || snapshot->mode != GlyphMode::Alpha ||
        snapshot->pixel_scale != 1.0f || !engine.prepared_glyphs_current(*snapshot))
        return 52;
    if (engine.published_glyphs(published_layout.id, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha) !=
        snapshot)
        return 53;
    const auto vertices_before = snapshot->vertices;
    const auto indices_before = snapshot->indices;
    PreparedGlyphs mutable_glyphs;
    if (!engine.prepare_glyphs(0.0f, 0.0f, 2.0f, GlyphMode::Alpha, mutable_glyphs))
        return 54;
    if (snapshot->vertices.size() != vertices_before.size() ||
        std::memcmp(snapshot->vertices.data(), vertices_before.data(),
                    vertices_before.size() * sizeof(GlyphVertex)) != 0 ||
        snapshot->indices != indices_before || snapshot->pixel_scale != 1.0f)
        return 55;
    if (engine.published_glyphs(published_layout.id, 0.0f, 0.0f, 2.0f, GlyphMode::Alpha) ==
        snapshot)
        return 56;
    const auto line_snapshot = engine.published_glyphs_for_line(published_layout.id, 0, 0.0f, 0.0f,
                                                                 1.0f, GlyphMode::Alpha);
    if (!line_snapshot || line_snapshot->layout_id != published_layout.id ||
        line_snapshot == snapshot ||
        engine.published_glyphs_for_line(published_layout.id, 0, 0.0f, 0.0f, 1.0f,
                                          GlyphMode::Alpha) != line_snapshot)
        return 57;
    if (engine.published_glyphs(0, 0.0f, 0.0f, 1.0f, GlyphMode::Alpha) ||
        engine.published_glyphs(published_layout.id, 0.0f, 0.0f, 0.0f, GlyphMode::Alpha) ||
        engine.published_glyphs_for_line(published_layout.id, 99, 0.0f, 0.0f, 1.0f,
                                          GlyphMode::Alpha))
        return 58;

    /* Foreground changes preserve geometry, measurement, rasterization and older snapshots. */
    TextLayoutResult styled_layout{};
    if (!engine.layout_utf8("abc\ndef", 200.0f, published_options, &styled_layout))
        return 59;
    const auto plain = engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha);
    const auto unaffected_line = engine.published_glyphs_for_line(styled_layout.id, 1, 0, 0, 1,
                                                             GlyphMode::Alpha);
    const auto before_colors = engine.stats();
    const auto before_builds = engine.layout_build_count();
    const GlyphTint red{255, 0, 0, 255};
    const std::vector<GlyphColorRange> colors{{0, 2, red}};
    const auto colored = engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha,
                                                {}, colors);
    if (!plain || !colored || !unaffected_line || colored == plain ||
        colored->source_ranges.empty() || colored->indices != plain->indices ||
        colored->vertices.size() != plain->vertices.size())
        return 60;
    for (const auto &source : colored->source_ranges) {
        for (uint32_t index = source.first_vertex;
             index < source.first_vertex + source.vertex_count; ++index) {
            const auto &vertex = colored->vertices[index];
            const auto &original = plain->vertices[index];
            if (vertex.x != original.x || vertex.y != original.y || vertex.u != original.u ||
                vertex.v != original.v || original.green != 255 || original.blue != 255 ||
                vertex.red != 255 || vertex.alpha != 255 ||
                vertex.green != (source.start < 2 ? 0 : 255) ||
                vertex.blue != (source.start < 2 ? 0 : 255))
                return 61;
        }
    }
    if (engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha, {}, colors) != colored ||
        engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha) != plain ||
        engine.published_glyphs_for_line(styled_layout.id, 1, 0, 0, 1, GlyphMode::Alpha,
                                         {}, colors) != unaffected_line ||
        engine.layout_build_count() != before_builds ||
        engine.stats().glyphs_rasterized != before_colors.glyphs_rasterized)
        return 62;
    const std::vector<GlyphColorRange> overlapping{{0, 2, red}, {1, 3, red}};
    const std::vector<GlyphColorRange> reversed{{2, 1, red}};
    const std::vector<GlyphColorRange> negative{{-1, 2, red}};
    if (engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha, {}, overlapping) ||
        engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha, {}, reversed) ||
        engine.published_glyphs(styled_layout.id, 0, 0, 1, GlyphMode::Alpha, {}, negative))
        return 63;
    auto recolored = *colored;
    apply_glyph_colors(recolored, {}, {});
    if (std::memcmp(recolored.vertices.data(), plain->vertices.data(),
                    plain->vertices.size() * sizeof(GlyphVertex)) != 0 ||
        colored->vertices[colored->source_ranges.front().first_vertex].green != 0)
        return 64;

    /* Metadata is in codepoints, including supplementary characters and visual RTL order. */
    TextLayoutResult unicode_layout{};
    if (!engine.layout_utf8("é🙂אבג", 200.0f, published_options, &unicode_layout))
        return 65;
    const std::vector<GlyphColorRange> unicode_colors{{1, 2, red}, {3, 5, red}};
    const auto unicode = engine.published_glyphs(unicode_layout.id, 0, 0, 1, GlyphMode::Alpha,
                                                {}, unicode_colors);
    if (!unicode || unicode->source_ranges.empty())
        return 66;
    bool saw_supplementary = false;
    bool saw_rtl = false;
    for (const auto &source : unicode->source_ranges) {
        if (source.start < 0 || source.end > 5 || source.end <= source.start)
            return 67;
        saw_supplementary |= source.start == 1;
        saw_rtl |= source.start >= 2;
        const bool is_red = source.start == 1 || source.start >= 3;
        if (unicode->vertices[source.first_vertex].green != (is_red ? 0 : 255))
            return 68;
    }
    if (!saw_supplementary || !saw_rtl)
        return 69;

    // Changing one row's foreground must keep every unaffected published
    // row and the measured layout, including general Unicode shaping.
    {
        TextEngine rows(shared_fonts);
        TextLayoutResult layout;
        if (!rows.layout_utf8("é first\nsecond é\nthird", 400.0f, published_options, &layout) ||
            layout.lines.size() != 3)
            return 190;
        const auto first = rows.published_glyphs_for_line(layout.id, 0, 0, 0, 1, GlyphMode::Alpha);
        const auto middle = rows.published_glyphs_for_line(layout.id, 1, 0, 0, 1, GlyphMode::Alpha);
        const auto last = rows.published_glyphs_for_line(layout.id, 2, 0, 0, 1, GlyphMode::Alpha);
        if (!first || !middle || !last) return 191;
        const auto builds = rows.layout_build_count();
        const std::vector<GlyphColorRange> colors{{middle->source_start, middle->source_start + 3, red}};
        const auto changed = rows.published_glyphs_for_line(layout.id, 1, 0, 0, 1, GlyphMode::Alpha, {}, colors);
        if (!changed || changed == middle || rows.layout_build_count() != builds ||
            rows.published_glyphs_for_line(layout.id, 0, 0, 0, 1, GlyphMode::Alpha, {}, colors) != first ||
            rows.published_glyphs_for_line(layout.id, 2, 0, 0, 1, GlyphMode::Alpha, {}, colors) != last ||
            rows.published_glyphs_for_line(layout.id, 1, 0, 0, 1, GlyphMode::Alpha) != middle ||
            changed->vertices.size() != middle->vertices.size())
            return 192;
        for (size_t index = 0; index < changed->vertices.size(); ++index)
            if (changed->vertices[index].x != middle->vertices[index].x ||
                changed->vertices[index].y != middle->vertices[index].y)
                return 193;
    }

    // Publishing a middle visual line of a long wrapped paragraph must
    // contain only that line, with its origin normalized for line drawing.
    TextEngine long_word(shared_fonts);
    const std::string long_text(1024 * 1024, 'a');
    TextLayoutOptions long_options;
    long_options.font_size = 16.0f;
    TextLayoutResult long_layout;
    if (!long_word.layout_utf8(long_text.c_str(), 200.0f, long_options, &long_layout) ||
        long_layout.lines.size() < 1000)
        return 120;
    const uint32_t middle = static_cast<uint32_t>(long_layout.lines.size() / 2);
    const auto middle_glyphs = long_word.published_glyphs_for_line(
        long_layout.id, middle, 0, 0, 1, GlyphMode::Alpha);
    if (!middle_glyphs || middle_glyphs->vertices.empty() ||
        middle_glyphs->vertices.size() > 400)
        return 121;
    for (const auto &vertex : middle_glyphs->vertices)
        if (vertex.x < -20 || vertex.x > 220 || vertex.y < -30 || vertex.y > 50)
            return 122;
    if (long_word.published_glyphs_for_line(long_layout.id, middle, 0, 0, 1,
                                           GlyphMode::Alpha) != middle_glyphs)
        return 123;
    const auto &middle_line = long_layout.lines[middle];
    const auto visible = long_word.visible_lines(middle_line.bounds.y,
        middle_line.bounds.y + middle_line.bounds.height);
    if (visible.first > middle || visible.second <= middle ||
        visible.second - visible.first > 5)
        return 124;
    const auto viewport = long_word.published_glyphs_for_lines(long_layout.id,
        middle, middle + 1, 0, 0, 1, GlyphMode::Alpha);
    if (!viewport || viewport->vertices.size() != middle_glyphs->vertices.size())
        return 125;
    for (size_t i = 0; i < viewport->vertices.size(); ++i)
        if (std::abs(viewport->vertices[i].y - middle_glyphs->vertices[i].y - middle_line.bounds.y) > .1f ||
            viewport->vertices[i].red != middle_glyphs->vertices[i].red)
            return 126;
    const auto empty = long_word.published_glyphs_for_lines(long_layout.id,
        middle, middle, 0, 0, 1, GlyphMode::Alpha);
    if (!empty || !empty->vertices.empty() ||
        long_word.published_glyphs_for_lines(long_layout.id, middle + 1, middle, 0, 0, 1, GlyphMode::Alpha) ||
        long_word.published_glyphs_for_lines(long_layout.id, 0, long_layout.lines.size() + 1, 0, 0, 1, GlyphMode::Alpha))
        return 127;

    // An equal-length edit in one wrapped row retains glyph snapshots for
    // rows whose text range and placement stayed unchanged.
    const auto preceding = long_word.published_glyphs_for_line(
        long_layout.id, middle - 20, 0, 0, 1, GlyphMode::Alpha);
    const auto following = long_word.published_glyphs_for_line(
        long_layout.id, middle + 20, 0, 0, 1, GlyphMode::Alpha);
    const auto before_edit_stats = long_word.stats();
    TextLayoutResult edited_rows;
    const int32_t edit_offset = static_cast<int32_t>(middle_line.text_offset + 4);
    if (!preceding || !following ||
        !long_word.edit_utf8(edit_offset, edit_offset + 1, "e", &edited_rows) ||
        long_word.stats().incremental_ascii_edits != before_edit_stats.incremental_ascii_edits + 1 ||
        edited_rows.lines.size() != long_layout.lines.size())
        return 128;
    const bool before_reused = long_word.published_glyphs_for_line(long_layout.id, middle - 20, 0, 0, 1,
                                            GlyphMode::Alpha) == preceding;
    const bool after_reused = long_word.published_glyphs_for_line(long_layout.id, middle + 20, 0, 0, 1,
                                            GlyphMode::Alpha) == following;
    const bool changed_rebuilt = long_word.published_glyphs_for_line(long_layout.id, middle, 0, 0, 1,
                                            GlyphMode::Alpha) != middle_glyphs;
    if (!before_reused || !after_reused || !changed_rebuilt ||
        !long_word.prepared_glyphs_current(*preceding) ||
        !long_word.prepared_glyphs_current(*following) ||
        long_word.prepared_glyphs_current(*middle_glyphs))
        return 129;
    if (!long_word.edit_utf8(edit_offset, edit_offset, "a", &edited_rows) ||
        long_word.published_glyphs_for_line(long_layout.id, middle - 20, 0, 0, 1,
                                            GlyphMode::Alpha) != preceding ||
        !long_word.prepared_glyphs_current(*preceding))
        return 130;
    const auto after_insert = long_word.published_glyphs_for_line(
        long_layout.id, middle + 20, 0, 0, 1, GlyphMode::Alpha);
    const int32_t row_shift = after_insert ? after_insert->source_start - following->source_start : -1;
    if (!after_insert || (row_shift != 0 && row_shift != 1) ||
        (row_shift == 0 && after_insert != following) ||
        (row_shift == 1 && (after_insert == following ||
                            long_word.prepared_glyphs_current(*following))) ||
        after_insert->vertices.size() != following->vertices.size() ||
        after_insert->source_ranges.size() != following->source_ranges.size())
        return 134;
    for (size_t i = 0; i < after_insert->source_ranges.size(); ++i)
        if (after_insert->source_ranges[i].start != following->source_ranges[i].start + row_shift ||
            after_insert->source_ranges[i].end != following->source_ranges[i].end + row_shift)
            return 135;
    if (!after_insert || !long_word.edit_utf8(edit_offset, edit_offset + 1, "", &edited_rows) ||
        long_word.published_glyphs_for_line(long_layout.id, middle - 20, 0, 0, 1,
                                            GlyphMode::Alpha) != preceding ||
        !long_word.prepared_glyphs_current(*preceding) ||
        (row_shift != 0 && long_word.prepared_glyphs_current(*after_insert)))
        return 131;
    const auto after_delete = long_word.published_glyphs_for_line(
        long_layout.id, middle + 20, 0, 0, 1, GlyphMode::Alpha);
    if (!after_delete || after_delete->source_start != following->source_start ||
        !long_word.prepared_glyphs_current(*after_delete))
        return 136;

    // A wider inserted glyph can move an unchanged suffix row's codepoint range.
    TextEngine shifted(shared_fonts);
    std::string words(10000, 'i');
    TextLayoutResult word_layout;
    if (!shifted.layout_utf8(words.c_str(), 200.0f, long_options, &word_layout) ||
        word_layout.lines.size() < 30)
        return 137;
    const auto old_word_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha);
    const std::vector<GlyphColorRange> fixed_colors{{
        static_cast<int32_t>(word_layout.lines[20].text_offset + 2),
        static_cast<int32_t>(word_layout.lines[20].text_offset + 4), {255, 0, 0, 255}}};
    const auto old_colored_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha, {}, fixed_colors);
    TextLayoutResult shifted_layout;
    if (!old_word_row || !old_colored_row || !shifted.edit_utf8(2, 2, "w", &shifted_layout) ||
        shifted_layout.id != word_layout.id)
        return 138;
    const auto new_word_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha);
    const auto new_colored_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha, {}, fixed_colors);
    const int32_t shifted_delta = static_cast<int32_t>(shifted_layout.lines[20].text_offset) -
        static_cast<int32_t>(word_layout.lines[20].text_offset);
    auto moved_colors = fixed_colors;
    moved_colors[0].start += shifted_delta;
    moved_colors[0].end += shifted_delta;
    const auto moved_colored_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha, {}, moved_colors);
    if (!moved_colored_row || moved_colored_row == old_colored_row ||
        moved_colored_row->publication_key != old_colored_row->publication_key ||
        moved_colored_row->source_start != old_colored_row->source_start + shifted_delta ||
        !shifted.prepared_glyphs_current(*moved_colored_row) ||
        shifted.prepared_glyphs_current(*old_colored_row) ||
        moved_colored_row->vertices.size() != old_colored_row->vertices.size())
        return 144;
    for (size_t index = 0; index < moved_colored_row->vertices.size(); ++index) {
        const auto &actual = moved_colored_row->vertices[index];
        const auto &previous = old_colored_row->vertices[index];
        if (actual.x != previous.x || actual.y != previous.y ||
            actual.red != previous.red || actual.green != previous.green ||
            actual.blue != previous.blue || actual.alpha != previous.alpha)
            return 145;
    }
    if (!new_word_row || !new_colored_row || new_colored_row == old_colored_row ||
        shifted_delta == 0 || new_word_row == old_word_row ||
        new_word_row->source_start != old_word_row->source_start + shifted_delta ||
        shifted.prepared_glyphs_current(*old_word_row) ||
        !shifted.prepared_glyphs_current(*new_word_row) ||
        new_word_row->vertices.size() != old_word_row->vertices.size() ||
        new_word_row->source_ranges.size() != old_word_row->source_ranges.size())
        return 139;
    for (const auto &source : new_colored_row->source_ranges) {
        const bool in_color_range = source.start >= fixed_colors[0].start &&
            source.start < fixed_colors[0].end;
        const auto &vertex = new_colored_row->vertices[source.first_vertex];
        if ((vertex.green == 0) != in_color_range)
            return 143;
    }
    for (size_t i = 0; i < new_word_row->source_ranges.size(); ++i)
        if (new_word_row->source_ranges[i].start != old_word_row->source_ranges[i].start + shifted_delta ||
            new_word_row->source_ranges[i].end != old_word_row->source_ranges[i].end + shifted_delta)
            return 140;
    if (!shifted.edit_utf8(2, 3, "", &shifted_layout) ||
        shifted_layout.id != word_layout.id ||
        shifted.prepared_glyphs_current(*new_word_row))
        return 141;
    const auto restored_word_row = shifted.published_glyphs_for_line(
        word_layout.id, 20, 0, 0, 1, GlyphMode::Alpha);
    if (!restored_word_row || restored_word_row->source_start != old_word_row->source_start ||
        !shifted.prepared_glyphs_current(*restored_word_row))
        return 142;

    // An offset-shifting edit may preserve the same row's source range and
    // pixels (a repeated run), but it must not preserve a different row.
    TextEngine varied(shared_fonts);
    std::string varying;
    for (int index = 0; index < 4096; ++index)
        varying.push_back(static_cast<char>('a' + index % 26));
    TextLayoutResult varying_layout;
    if (!varied.layout_utf8(varying.c_str(), 200.0f, long_options, &varying_layout) ||
        varying_layout.lines.size() < 40)
        return 132;
    const auto varying_after = varied.published_glyphs_for_line(
        varying_layout.id, 30, 0, 0, 1, GlyphMode::Alpha);
    if (!varying_after || !varied.edit_utf8(5, 5, "a", nullptr) ||
        varied.published_glyphs_for_line(varying_layout.id, 30, 0, 0, 1,
                                         GlyphMode::Alpha) == varying_after ||
        varied.prepared_glyphs_current(*varying_after))
        return 133;


    // Full Unicode reshaping must retain only rows whose rendered glyphs and
    // cluster source mapping match. Snapshots retain their old layout lifetime.
    {
        auto fonts = std::make_shared<FontCollection>();
        if (!fonts->add_font(NKUI_TEST_FONT_PATH) ||
            !fonts->add_font(NKUI_TEST_COLOR_FONT_PATH, FontFamily::Emoji) ||
            !fonts->add_system_fallbacks())
            return 146;
        TextEngine rows(fonts);
        TextLayoutResult before, after;
        const char *text = "é first\nsecond é 🙂 אבג\nthird";
        auto row_options = long_options;
        // Binary-exact row spacing isolates movement from fractional-origin
        // cancellation, which intentionally fails the exact reuse guard.
        row_options.line_height = 24.0f;
        // Resolve system fallback fonts before exercising stable generations.
        if (!rows.layout_utf8(text, 400.0f, row_options, &before) ||
            !rows.layout_utf8(text, 400.0f, row_options, &before) ||
            before.lines.size() != 3)
            return 147;
        const auto first = rows.published_glyphs_for_line(before.id, 0, 0, 0, 1,
                                                         GlyphMode::Alpha);
        const auto plain = rows.published_glyphs_for_line(before.id, 1, 0, 0, 1,
                                                         GlyphMode::Alpha);
        if (!first || !plain)
            return 148;
        std::vector<GlyphColorRange> colors{{plain->source_start, plain->source_start + 3,
                                           {255, 0, 0, 255}}};
        const auto colored = rows.published_glyphs_for_line(before.id, 1, 0, 0, 1,
                                                           GlyphMode::Alpha, {}, colors);
        if (!colored || !rows.edit_utf8(0, 1, "ö", &after) || after.id == before.id)
            return 149;
        const auto retained = rows.published_glyphs_for_line(after.id, 1, 0, 0, 1,
                                                            GlyphMode::Alpha, {}, colors);
        const auto changed = rows.published_glyphs_for_line(after.id, 0, 0, 0, 1,
                                                           GlyphMode::Alpha);
        if (!retained || !changed || retained == colored ||
            retained->publication_key != colored->publication_key ||
            changed->publication_key == first->publication_key ||
            !rows.prepared_glyphs_current(*retained) ||
            !rows.prepared_glyphs_current(*colored))
            return 150;
        if (!rows.edit_utf8(1, 1, "é", &after))
            return 151;
        colors[0].start++;
        colors[0].end++;
        const auto shifted = rows.published_glyphs_for_line(after.id, 1, 0, 0, 1,
                                                           GlyphMode::Alpha, {}, colors);
        if (!shifted || shifted->publication_key != colored->publication_key ||
            shifted->source_start != colored->source_start + 1 ||
            shifted->vertices.size() != colored->vertices.size() ||
            shifted->source_ranges.size() != colored->source_ranges.size() ||
            !rows.prepared_glyphs_current(*shifted))
            return 152;
        for (size_t i = 0; i < shifted->vertices.size(); ++i) {
            const auto &a = shifted->vertices[i];
            const auto &b = colored->vertices[i];
            if (a.x != b.x || a.y != b.y || a.red != b.red || a.green != b.green ||
                a.blue != b.blue || a.alpha != b.alpha)
                return 153;
        }
        for (size_t i = 0; i < shifted->source_ranges.size(); ++i)
            if (shifted->source_ranges[i].start != colored->source_ranges[i].start + 1 ||
                shifted->source_ranges[i].end != colored->source_ranges[i].end + 1)
                return 154;
        if (!rows.edit_utf8(0, 0, "\n", &after) || after.lines.size() != 4)
            return 155;
        colors[0].start++;
        colors[0].end++;
        const auto moved = rows.published_glyphs_for_line(after.id, 2, 0, 0, 1,
                                                        GlyphMode::Alpha, {}, colors);
        if (!moved || moved->publication_key != shifted->publication_key ||
            moved->first_line != 2 || moved->end_line != 3 ||
            moved->source_start != shifted->source_start + 1 ||
            !rows.prepared_glyphs_current(*moved) ||
            moved->vertices.size() != shifted->vertices.size())
            return 156;
        for (size_t i = 0; i < moved->vertices.size(); ++i)
            if (moved->vertices[i].x != shifted->vertices[i].x ||
                moved->vertices[i].y != shifted->vertices[i].y ||
                moved->vertices[i].red != shifted->vertices[i].red ||
                moved->vertices[i].green != shifted->vertices[i].green)
                return 157;
        for (size_t i = 0; i < moved->source_ranges.size(); ++i)
            if (moved->source_ranges[i].start != shifted->source_ranges[i].start + 1 ||
                moved->source_ranges[i].end != shifted->source_ranges[i].end + 1)
                return 160;
        if (!rows.edit_utf8(0, 1, "", &after) || after.lines.size() != 3)
            return 158;
        colors[0].start--;
        colors[0].end--;
        const auto restored = rows.published_glyphs_for_line(after.id, 1, 0, 0, 1,
                                                           GlyphMode::Alpha, {}, colors);
        if (!restored || restored->publication_key != moved->publication_key ||
            restored->first_line != 1 || restored->end_line != 2 ||
            restored->source_start != shifted->source_start ||
            moved->first_line != 2 || !rows.prepared_glyphs_current(*restored))
            return 159;
    }
    return glyphs.vertices.size() % 4 == 0 && glyphs.indices.size() % 6 == 0 ? 0 : 41;
}
