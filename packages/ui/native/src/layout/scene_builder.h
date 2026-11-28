#ifndef NATIVEKIT_UI_SCENE_BUILDER_H
#define NATIVEKIT_UI_SCENE_BUILDER_H

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
class SceneBuilder {
  public:
    SceneBuilder();
    explicit SceneBuilder(std::shared_ptr<FontCollection> fonts);
    ~SceneBuilder();
    SceneBuilder(const SceneBuilder &) = delete;
    SceneBuilder &operator=(const SceneBuilder &) = delete;

    bool valid() const;
    TextEngine *text_engine();
    const TextEngine *text_engine() const;
    bool add_font(const char *path, FontFamily family = FontFamily::Default);
    bool add_font_from_data(const char *name, const void *data, std::size_t bytes,
                            FontFamily family = FontFamily::Default);
    bool add_system_fallbacks();

    /** Builds `out` from `nodes`, each where its placement puts it, in a `width` by `height` viewport. */
    bool build(const LayoutNodeView &nodes, float width, float height, LayoutSnapshot &out,
               LayoutError *error = nullptr, const LayoutInputChanges *changes = nullptr);

    bool build(const std::vector<LayoutNode> &nodes, float width, float height, LayoutSnapshot &out,
               LayoutError *error = nullptr, const LayoutInputChanges *changes = nullptr);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace nkui

#endif
