#ifndef NATIVEKIT_UI_LAYOUT_ENGINE_H
#define NATIVEKIT_UI_LAYOUT_ENGINE_H

#include "layout/layout_types.h"

#include <cstddef>
#include <memory>

namespace nkui {

class TextEngine;
class FontCollection;

/**
 * Builds a retained session's scene from nodes the framework has laid out (ADR 0009): resolves transforms, clips,
 * content and hit bounds from their placements, shapes their text at the widths it was given, and emits the paint
 * primitives in paint order.
 */
class LayoutEngine {
  public:
    explicit LayoutEngine(std::size_t initial_capacity = 512);
    explicit LayoutEngine(std::shared_ptr<FontCollection> fonts,
                          std::size_t initial_capacity = 512);
    ~LayoutEngine();
    LayoutEngine(const LayoutEngine &) = delete;
    LayoutEngine &operator=(const LayoutEngine &) = delete;

    bool valid() const;
    TextEngine *text_engine();
    const TextEngine *text_engine() const;
    bool add_font(const char *path, FontFamily family = FontFamily::Default);
    bool add_font_from_data(const char *name, const void *data, std::size_t bytes,
                            FontFamily family = FontFamily::Default);
    bool add_system_fallbacks();

    /** Builds `out` from `nodes`, each placed by the entry of `placements` with its ID, in a `width` by `height` viewport. */
    bool layout(const LayoutNodeView &nodes, const std::vector<LayoutPlacement> &placements, float width,
                float height, LayoutSnapshot &out, LayoutError *error = nullptr,
                const LayoutInputChanges *changes = nullptr);

    bool layout(const std::vector<LayoutNode> &nodes, const std::vector<LayoutPlacement> &placements,
                float width, float height, LayoutSnapshot &out, LayoutError *error = nullptr,
                const LayoutInputChanges *changes = nullptr);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace nkui

#endif
