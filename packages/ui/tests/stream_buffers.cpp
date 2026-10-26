#include "render/ui_renderer.h"
#include "nativekit.h"
#include "nativekit_window.h"
#include "nativekit_time.h"
#include "nativekit_gpu.h"
#include "testing.h"
#if defined(__APPLE__)
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#elif defined(_WIN32)
#include <windows.h>
#include <GL/gl.h>
#else
#include <GL/gl.h>
#endif
#include <array>
#include <cstdio>
#include <vector>

namespace {
bool check(bool value, const char *message, nkui::UiRenderer *renderer = nullptr) {
    if (!value) std::fprintf(stderr, "stream buffers: %s: %s\n", message,
        renderer ? renderer->lastError() : nk_last_error());
    return value;
}
const float identity[6] = {1, 0, 0, 1, 0, 0};
nkui::PreparedTexture texture(uint32_t token, std::vector<uint8_t> pixels) {
    nkui::PreparedTexture result{};
    result.token = token; result.width = result.height = 1; result.generation = 1;
    result.pixels = std::move(pixels);
    return result;
}
bool pixels_match(bool swapped = false) {
    std::array<uint8_t, 4> left{}, right{};
    glReadPixels(16, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, left.data());
    glReadPixels(48, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, right.data());
    if (swapped) std::swap(left, right);
    return left[0] > 240 && left[2] < 10 && right[0] < 10 && right[2] > 240;
}
bool raster_reuse(nk_surface surface, bool recorded) {
    auto renderer = nkui::create_ui_renderer(surface);
    if (!check(renderer && renderer->initialize(), "initialize raster reuse", renderer.get())) return false;
    auto red = texture(1, {255, 0, 0, 255});
    auto blue = texture(2, {0, 0, 255, 255});
    auto white = texture(3, {255, 255, 255, 255});
    const auto target = nkui::make_resource_id(nkui::ResourceKind::RenderTarget, 1, 0x8000);
    nkui::UiRendererStats full{};
    // Establish the borrowed window framebuffer before the offscreen passes.
    // Overflow the 128-entry cache with equal-sized, changing contents. Its
    // GPU allocation count must plateau while every new result still renders.
    for (uint64_t key = 1; key <= 144; ++key) {
        bool hit = false;
        const bool swapped = key % 2 == 0;
        if (!check(renderer->beginFrame(recorded) &&
                   renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
                   renderer->beginRasterPass(target, key, 64, 64, hit) && !hit &&
                   renderer->drawImage(swapped ? blue : red, 0, 0, 32, 64, identity) &&
                   renderer->drawImage(swapped ? red : blue, 32, 0, 32, 64, identity) &&
                   renderer->endPass() && renderer->beginWindowPass(64, 64, true) &&
                   renderer->compositeImage(target, 0, 0, 64, 64, identity, 1, {1, 1}) &&
                   renderer->endFrame() && pixels_match(swapped),
                   "raster replacement pixels", renderer.get())) {
            std::array<uint8_t, 4> left{}, right{};
            glReadPixels(16, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, left.data());
            glReadPixels(48, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, right.data());
            std::fprintf(stderr, "raster key=%llu recorded=%d left=%u,%u,%u right=%u,%u,%u\n",
                static_cast<unsigned long long>(key), recorded, left[0], left[1], left[2], right[0], right[1], right[2]);
            return false;
        }
        auto stats = renderer->stats();
        if (key == 128) full = stats;
        if (key > 128 && !check(stats.gpu.resource_creations == full.gpu.resource_creations &&
                              stats.gpu.resource_destructions == full.gpu.resource_destructions &&
                              stats.raster_cache_entries == 128 &&
                              stats.raster_cache_bytes == full.raster_cache_bytes,
                              "raster replacement allocated or grew the cache", renderer.get())) return false;
    }
    // A hit protects the oldest entry while another key needs a replacement.
    const auto protected_target = nkui::make_resource_id(nkui::ResourceKind::RenderTarget, 1, 0x8001);
    bool hit = false;
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
               renderer->beginRasterPass(protected_target, 17, 64, 64, hit) && hit &&
               renderer->beginRasterPass(target, 145, 64, 64, hit) && !hit &&
               renderer->drawImage(blue, 0, 0, 64, 64, identity) && renderer->endPass() &&
               renderer->beginWindowPass(64, 64, true) &&
               renderer->compositeImage(protected_target, 0, 0, 64, 64, identity, 1, {1, 1}) &&
               renderer->endFrame() && pixels_match(), "current-frame raster was recycled", renderer.get())) return false;
    // A recycled target must be cleared, not retain the unused right half.
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
               renderer->beginRasterPass(target, 146, 64, 64, hit) &&
               !hit && renderer->drawImage(red, 0, 0, 32, 64, identity) && renderer->endPass() &&
               renderer->beginWindowPass(64, 64, true) &&
               renderer->drawImage(white, 0, 0, 64, 64, identity) &&
               renderer->compositeImage(target, 0, 0, 64, 64, identity, 1, {1, 1}) &&
               renderer->endFrame(), "clear recycled raster", renderer.get())) return false;
    std::array<uint8_t, 4> right{};
    glReadPixels(48, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, right.data());
    if (!check(right[0] > 240 && right[1] > 240 && right[2] > 240,
               "recycled raster retained old pixels", renderer.get())) return false;
    // Aborting a replacement cannot publish its unfinished contents as a hit.
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
               renderer->beginRasterPass(target, 147, 64, 64, hit) &&
               !hit, "begin aborted replacement", renderer.get())) return false;
    renderer->abortFrame();
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
               renderer->beginRasterPass(target, 147, 64, 64, hit) &&
               !hit && renderer->drawImage(red, 0, 0, 32, 64, identity) &&
               renderer->drawImage(blue, 32, 0, 32, 64, identity) && renderer->endPass() &&
               renderer->beginWindowPass(64, 64, true) &&
               renderer->compositeImage(target, 0, 0, 64, 64, identity, 1, {1, 1}) &&
               renderer->endFrame() && pixels_match(), "retry aborted replacement", renderer.get())) return false;
    // An incompatible size still allocates correctly and renders at its new extent.
    const auto before_resize = renderer->stats();
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) && renderer->endPass() &&
               renderer->beginRasterPass(target, 148, 32, 32, hit) && !hit &&
               renderer->drawImage(red, 0, 0, 16, 32, identity) &&
               renderer->drawImage(blue, 16, 0, 16, 32, identity) && renderer->endPass() &&
               renderer->beginWindowPass(64, 64, true) &&
               renderer->compositeImage(target, 0, 0, 64, 64, identity, 1, {1, 1}) &&
               renderer->endFrame() && pixels_match() &&
               renderer->stats().gpu.resource_creations > before_resize.gpu.resource_creations &&
               renderer->stats().raster_cache_entries == 128,
               "raster size change", renderer.get())) return false;
    return true;
}
bool run(nk_surface surface, bool recorded) {
    nkui::UiStreamBufferConfig config{64, 64, 64, 8192};
    auto renderer = nkui::create_ui_renderer(surface, nullptr, config);
    if (!check(renderer && renderer->initialize(), "initialize", renderer.get())) return false;
    auto red = texture(1, {255, 0, 0, 255});
    auto blue = texture(2, {0, 0, 255, 255});
    // Both streams must support a single mesh larger than a normal page.
    std::vector<nkui::SurfaceMeshVertex> vertices(128, {0, 0, 0, 0, 255, 0, 255});
    vertices[0].x = -.5f; vertices[0].y = -.5f;
    vertices[1].x = .5f; vertices[1].y = -.5f;
    vertices[2].y = .5f;
    std::vector<uint32_t> indices;
    for (int index = 0; index < 64; ++index) indices.insert(indices.end(), {0, 1, 2});
    nkui::SurfaceMeshView mesh{vertices, indices, {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}};
    nkui::UiRendererStats high_water{};
    for (int frame = 0; frame < 6; ++frame) {
        if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true),
                   "begin frame", renderer.get())) return false;
        if (!check(renderer->drawSurfaceMesh(mesh), "oversized mesh", renderer.get())) return false;
        for (int index = 0; index < 10; ++index) {
            if (!check(renderer->drawImage(red, 0, 0, 32, 64, identity) &&
                       renderer->drawImage(blue, 32, 0, 32, 64, identity),
                       "roll over page", renderer.get())) return false;
        }
        if (!check(renderer->endFrame(), "submit frame", renderer.get()) ||
            !check(frame > 0 && frame < 5 ? true : pixels_match(), "page rollover corrupted pixels")) return false;
        auto stats = renderer->stats();
        if (!frame) high_water = stats;
        else if (!check(stats.gpu.buffer_bytes == high_water.gpu.buffer_bytes &&
                        stats.gpu.buffers_live == high_water.gpu.buffers_live &&
                        stats.gpu.resource_creations == high_water.gpu.resource_creations,
                        "pages were not reused", renderer.get())) return false;
    }
    if (!check(high_water.gpu.buffers_live > 5 && high_water.gpu.buffer_bytes <= 8192,
               "page budget or allocation count", renderer.get())) return false;
    renderer.reset();

    // A rejected recorded frame must not be replayed, and its next frame must work.
    config.memory_budget_bytes = 320;
    renderer = nkui::create_ui_renderer(surface, nullptr, config);
    if (!check(renderer->initialize(), "initialize bounded renderer", renderer.get())) return false;
    for (int attempt = 0; attempt < 3; ++attempt) {
        if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) &&
                   renderer->drawImage(red, 0, 0, 32, 64, identity), "first bounded draw", renderer.get())) return false;
        if (!check(!renderer->drawImage(blue, 32, 0, 32, 64, identity) && renderer->resourceLimited(),
                   "budget exhaustion was not recoverable", renderer.get())) return false;
        renderer->abortFrame();
        if (!check(renderer->beginFrame(recorded) && !renderer->resourceLimited() &&
                   renderer->beginWindowPass(64, 64, true) &&
                   renderer->drawImage(red, 0, 0, 64, 64, identity) && renderer->endFrame(),
                   "retry after budget exhaustion", renderer.get())) return false;
    }
    renderer.reset();
    config.memory_budget_bytes = 8192;
    renderer = nkui::create_ui_renderer(surface, nullptr, config);
    if (!check(renderer->initialize() && renderer->beginFrame(recorded) &&
               renderer->beginWindowPass(64, 64, true) &&
               renderer->drawImage(red, 0, 0, 32, 64, identity), "allocation failure setup", renderer.get())) return false;
    nkgpu_test_fail_next_buffer_creation();
    if (!check(!renderer->drawImage(blue, 32, 0, 32, 64, identity) && renderer->resourceLimited(),
               "allocation failure classification", renderer.get())) return false;
    renderer->abortFrame();
    if (!check(renderer->beginFrame(recorded) && renderer->beginWindowPass(64, 64, true) &&
               renderer->drawImage(red, 0, 0, 32, 64, identity) &&
               renderer->drawImage(blue, 32, 0, 32, 64, identity) && renderer->endFrame() && pixels_match(),
               "retry after allocation failure", renderer.get())) return false;
    return true;
}
}
int main() {
    nk_init_options init{}; init.struct_size = sizeof(init); init.api_version = NK_API_VERSION;
    if (nk_init(&init) != NK_OK) return 1;
    nk_window_options options{}; options.struct_size = sizeof(options);
    options.width = options.height = 64; options.title = "UIKit stream buffers";
    nk_window window = 0; nk_surface surface = 0;
    bool success = nk_window_create(&options, &window) == NK_OK;
    if (success) success = nkgpu_surface_create(window, 64, 64, &surface) == NKGPU_OK;
    if (success) success = nk_window_activate(window) == NK_OK;
    bool ready = false;
    for (int attempt = 0; success && !ready && attempt < 500; ++attempt) {
        nk_event event{}; event.struct_size = sizeof(event);
        success = nk_poll_event(&event) == NK_OK;
        nk_event_release(&event);
        ready = nk_surface_make_current(surface) == NK_OK;
        if (!ready) nk_wait_events_timeout(.01);
    }
    if (success && ready) success = run(surface, false) && run(surface, true) &&
                                  raster_reuse(surface, false) && raster_reuse(surface, true);
    else success = false;
    if (surface) nk_surface_destroy(surface);
    if (window) nk_window_destroy(window);
    nk_shutdown();
    if (success) std::puts("PASS: stream pages, raster recycling, pixels, budgets and allocation recovery");
    return success ? 0 : 1;
}
