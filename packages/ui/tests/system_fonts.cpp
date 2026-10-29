#include "prepare/system_fonts.h"
#include "skribidi/skb_font_collection.h"
#include "skribidi/skb_layout.h"

#include <cstdio>
#include <memory>
#include <vector>

struct FallbackProbe {
    skb_font_handle_t handle = 0;
    uint32_t requested = 0;
    int calls = 0;
};

static skb_font_handle_t resolve(skb_font_collection_t *, const char *, uint32_t codepoint,
                                  uint8_t, void *context) {
    auto &probe = *static_cast<FallbackProbe *>(context);
    probe.requested = codepoint;
    ++probe.calls;
    return probe.handle;
}

struct GlyphProbe {
    int count = 0;
    int missing = 0;
    std::vector<skb_font_handle_t> fonts;
};
static bool glyph(const skb_layout_render_glyph_t *item, void *context) {
    auto &probe = *static_cast<GlyphProbe *>(context);
    ++probe.count;
    probe.fonts.push_back(item->font_handle);
    if (!item->glyph_id) ++probe.missing;
    return true;
}

int main() {
    auto fonts = std::unique_ptr<skb_font_collection_t, decltype(&skb_font_collection_destroy)>(
        skb_font_collection_create(), skb_font_collection_destroy);
    auto scratch = std::unique_ptr<skb_temp_alloc_t, decltype(&skb_temp_alloc_destroy)>(
        skb_temp_alloc_create(4096), skb_temp_alloc_destroy);
    const auto primary = skb_font_collection_add_font(fonts.get(), NKUI_TEST_FONT_PATH,
                                                      SKB_FONT_FAMILY_DEFAULT, nullptr);
    // Put the fallback in a different family so ordinary matching cannot select it.
    const auto fallback = skb_font_collection_add_font(fonts.get(), NKUI_TEST_MONO_FONT_PATH,
                                                       SKB_FONT_FAMILY_MONOSPACE, nullptr);
    if (!primary || !fallback || skb_font_collection_font_has_codepoint(fonts.get(), primary, 0x2500) ||
        !skb_font_collection_font_has_codepoint(fonts.get(), fallback, 0x2500)) return 1;
    FallbackProbe probe{fallback};
    skb_font_collection_set_on_codepoint_fallback(fonts.get(), resolve, &probe);
    skb_layout_params_t params{};
    params.font_collection = fonts.get();
    params.layout_width = 1000;
    const skb_attribute_t attributes[] = {skb_attribute_make_font_size(14)};
    const auto shape = [&](const char *text) {
        auto layout = std::unique_ptr<skb_layout_t, decltype(&skb_layout_destroy)>(
            skb_layout_create_utf8(scratch.get(), &params, text, -1,
                SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(attributes)), skb_layout_destroy);
        GlyphProbe result;
        if (layout) skb_layout_iterate_render_glyphs(layout.get(), glyph, &result);
        return result;
    };
    const auto resolved = shape("A─┌B");
    if (resolved.count != 4 || resolved.missing || probe.calls != 1 || probe.requested != 0x2500)
        return 2;
    // A symbol fallback may also contain Latin. It must not take over the
    // rest of the run simply because it can render the following letters.
    if (resolved.fonts != std::vector<skb_font_handle_t>{primary, fallback, fallback, primary})
        return 8;
    const auto prefix = shape("─AB");
    if (prefix.missing || prefix.fonts != std::vector<skb_font_handle_t>{fallback, primary, primary})
        return 9;
    const auto middle = shape("AB─CD");
    if (middle.missing || middle.fonts != std::vector<skb_font_handle_t>{primary, primary, fallback, primary, primary})
        return 10;
    const auto repeated = shape("A─B─C");
    if (repeated.missing || repeated.fonts != std::vector<skb_font_handle_t>{primary, fallback, primary, fallback, primary})
        return 11;
    const auto combining = shape("─ÁB");
    if (combining.missing || combining.fonts.size() < 3 || combining.fonts[0] != fallback)
        return 12;
    // Returning to the primary must keep the base and combining mark together.
    for (std::size_t i = 1; i < combining.fonts.size(); ++i)
        if (combining.fonts[i] != primary) return 13;
    // A bad callback must not make the shaper accept a font without coverage.
    probe.handle = primary;
    probe.calls = 0;
    const auto unavailable = shape("─");
    if (unavailable.count != 1 || unavailable.missing != 1 || probe.calls != 1) return 3;
    skb_font_collection_set_on_codepoint_fallback(fonts.get(), nullptr, nullptr);
    if (shape("─").missing != 1) return 4;
    auto empty = std::unique_ptr<skb_font_collection_t, decltype(&skb_font_collection_destroy)>(
        skb_font_collection_create(), skb_font_collection_destroy);
    probe.handle = 0xffffffff;
    skb_font_collection_set_on_codepoint_fallback(empty.get(), resolve, &probe);
    params.font_collection = empty.get();
    if (shape("A").count != 0) return 7;
    params.font_collection = fonts.get();

    if (!nkui::system_font_fallbacks_for_codepoint(0x110000, true, false).empty() ||
        !nkui::system_font_fallbacks_for_codepoint(0xd800, true, false).empty()) return 5;
    // Actual platform discovery is optional on hosts without installed symbol fonts.
    for (const auto codepoint : {0x2801u, 0x28ffu, 0x1fb00u}) {
        const auto candidates = nkui::system_font_fallbacks_for_codepoint(codepoint, true, false);
        if (candidates.empty()) {
            std::printf("SKIP: no platform font for U+%04X\n", codepoint);
            continue;
        }
        bool covered = false;
        for (const auto &candidate : candidates) {
            const auto handle = skb_font_collection_add_font(fonts.get(), candidate.path.c_str(),
                                                              SKB_FONT_FAMILY_MONOSPACE, nullptr);
            if (skb_font_collection_font_has_codepoint(fonts.get(), handle, codepoint)) {
                covered = true;
                break;
            }
        }
        if (!covered) return 6;
    }
    std::puts("PASS: missing-character callbacks, coverage validation and platform font discovery");
    return 0;
}
