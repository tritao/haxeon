#include "render/frame_resources.h"

#include "prepare/nanovg_recorder.h"
#include "nanovg.h"

using namespace nkui;

class TestProducer final : public SurfaceProducer {
  public:
    bool ready() const override { return true; }
    bool describe(int requested_width, int requested_height,
                  SurfaceDescriptor &description) const override {
        description = {requested_width, requested_height, SurfacePixelFormat::Rgba8,
                       SurfaceAlphaMode::Premultiplied};
        return true;
    }
    uint32_t generation() const override { return 7; }
    SurfaceRenderResult render(UiRenderer &, ResourceId, const SurfaceDescriptor &) override {
        return SurfaceRenderResult::Rendered;
    }
};

int main() {
    NanoVGRecorder recorder;
    NVGcontext *vg = recorder.context();
    nvgBeginFrame(vg, 100.0f, 100.0f, 1.0f);
    nvgBeginPath(vg);
    nvgRect(vg, 0.0f, 0.0f, 10.0f, 10.0f);
    nvgFill(vg);
    nvgEndFrame(vg);
    const auto path = make_resource_id(ResourceKind::Path, 2, 3);
    const auto text = make_resource_id(ResourceKind::TextLayout, 2, 4);
    const auto surface = make_resource_id(ResourceKind::RenderTarget, 2, 5);
    PreparedGlyphs glyphs;
    FrameResources resources;
    TestProducer producer;
    if (!resources.bind_path(path, recorder.data(), 0, 42) ||
        resources.bind_path(text, recorder.data(), 0) ||
        resources.bind_path(path, recorder.data(), 1) || !resources.bind_text(text, glyphs) ||
        resources.bind_text(path, glyphs) || !resources.bind_surface(surface, producer) ||
        resources.bind_surface(path, producer))
        return 1;
    if (!resources.path(path) || resources.path(path)->operation_index != 0 ||
        resources.text(text) != &glyphs || resources.surface(surface) != &producer ||
        resources.content_generation(path) != 42)
        return 2;
    const auto temporary = make_resource_id(ResourceKind::TextLayout, 4093, 8);
    if (resources.bind_text(temporary, glyphs, 0, text) ||
        resources.bind_text(temporary, glyphs, 19, path) ||
        !resources.bind_text(temporary, glyphs, 19, text) ||
        resources.source_identity(temporary).value != text.value ||
        resources.content_generation(temporary) != 19 ||
        resources.source_identity(path).value != path.value)
        return 4;
    OwnedFrameResources owned;
    auto snapshot = std::make_shared<PreparedGlyphs>();
    if (!owned.bind_text(temporary, snapshot, 19, text) ||
        owned.source_identity(temporary).value != text.value)
        return 5;
    snapshot.reset();
    if (!owned.text(temporary))
        return 6;
    owned.reset();
    if (owned.text(temporary) || owned.source_identity(temporary).value != temporary.value)
        return 7;
    resources.reset();
    return !resources.path(path) && !resources.text(text) && !resources.surface(surface) ? 0 : 3;
}
