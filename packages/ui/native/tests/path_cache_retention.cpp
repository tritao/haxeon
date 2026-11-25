#include "nativekit.h"
#include "nativekit_graphics.h"
#include "nativekit_gpu.h"
#include "nativekit_ui.h"
#include "nativekit_window.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

template <class T> void append(std::vector<uint8_t> &bytes, const T &value) {
    const auto offset = bytes.size();
    bytes.resize(offset + sizeof(value));
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

int main() {
    nk_init_options init{};
    init.struct_size = sizeof(init);
    init.api_version = NK_API_VERSION;
    if (nk_init(&init) != NK_OK) return 1;
    nk_window_options options{};
    options.struct_size = sizeof(options);
    options.width = 64; options.height = 64;
    options.title = "Prepared path cache retention";
    nk_window window = 0;
    if (nk_window_create(&options, &window) != NK_OK) return 2;
    nk_surface_options surface_options{};
    surface_options.struct_size = sizeof(surface_options);
    surface_options.api = nkgpu_default_graphics_api();
    surface_options.flags = NK_SURFACE_STENCIL;
    if (surface_options.api == NK_GRAPHICS_OPENGL)
        surface_options.flags |= NK_SURFACE_FORWARD_COMPATIBLE;
    surface_options.major_version = 3;
    surface_options.minor_version = 3;
    surface_options.width = 64; surface_options.height = 64;
    nk_surface surface = 0;
    if (nk_surface_create(window, &surface_options, &surface) != NK_OK) return 3;
    int width = 0, height = 0;
    bool ready = false;
    for (int attempt = 0; attempt < 5000 && !ready; ++attempt) {
        nk_event event{}; event.struct_size = sizeof(event);
        if (nk_poll_event(&event) != NK_OK) return 4;
        if (event.kind == NK_EVENT_SURFACE_READY && event.source == surface)
            ready = nk_surface_make_current(surface) == NK_OK &&
                    nk_surface_get_framebuffer_size(surface, &width, &height) == NK_OK;
        nk_event_release(&event);
        if (!ready) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!ready) return 5;
    nkui_renderer renderer{};
    nkui_resource paint{};
    if (nkui_renderer_create(&renderer) != NKUI_OK ||
        nkui_paint_create_solid({0.0f, 1.0f, 0.0f, 1.0f}, &paint) != NKUI_OK) return 6;
    const nkui_path_element path_elements[] = {
        {NKUI_PATH_MOVE_TO, {4, 4}}, {NKUI_PATH_LINE_TO, {20, 4}},
        {NKUI_PATH_LINE_TO, {20, 20}}, {NKUI_PATH_LINE_TO, {4, 20}},
        {NKUI_PATH_CLOSE, {}}};
    int result = 0;
    // Keep a hot path alive while more than one cache capacity of transient
    // paths passes through. Crossing capacity must not discard the hot entry.
    if (!result) {
        nkui_resource hot_path{};
        if (nkui_path_create(path_elements, 5, &hot_path) != NKUI_OK) result = 40;
        const nkui_frame_info info{sizeof(info), static_cast<float>(width),
                                  static_cast<float>(height), width, height, 1.0f};
        for (int iteration = 0; iteration < 300 && !result; ++iteration) {
            nkui_resource cold_path{};
            nkui_display_list probe{};
            if (nkui_path_create(path_elements, 5, &cold_path) != NKUI_OK ||
                nkui_display_list_create(&probe) != NKUI_OK) { result = 40; break; }
            std::vector<uint8_t> bytes;
            append(bytes, nkui_resource_command{{NKUI_COMMAND_SET_PAINT, NKUI_COMMAND_VERSION,
                                                 sizeof(nkui_resource_command)}, paint});
            for (const auto resource : {hot_path, cold_path})
                append(bytes, nkui_resource_command{{NKUI_COMMAND_DRAW_PATH, NKUI_COMMAND_VERSION,
                                                     sizeof(nkui_resource_command)}, resource});
            nkui_renderer_stats before{}, after{};
            if (nkui_renderer_get_stats(renderer, &before) != NKUI_OK ||
                nkui_display_list_submit(probe, bytes.data(), bytes.size()) != NKUI_OK ||
                nkui_renderer_render_frame(renderer, probe, surface, &info) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &after) != NKUI_OK ||
                nk_surface_present(surface) != NK_OK) result = 40;
            if (!result && iteration > 0 &&
                (after.path_cache_misses != before.path_cache_misses + 1 ||
                 after.path_cache_hits != before.path_cache_hits + 1 ||
                 (iteration >= 256 && after.path_geometry_bytes_retained != before.path_geometry_bytes_retained))) {
                std::fprintf(stderr, "hot path evicted during transient churn at %d\n", iteration);
                result = 40;
            }
            nkui_display_list_destroy(probe);
            nkui_resource_destroy(cold_path);
        }
        nkui_resource_destroy(hot_path);
        if (!result) std::puts("PASS: hot prepared path survives 300 transient paths");
    }
    nkui_resource_destroy(paint);
    nkui_renderer_destroy(renderer);
    nk_surface_destroy(surface);
    nk_window_destroy(window);
    nk_shutdown();
    return result;
}
