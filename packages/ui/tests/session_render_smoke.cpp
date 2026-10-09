#include "nativekit.h"
#include "nativekit_graphics.h"
#include "nativekit_gpu.h"
#include "nativekit_ui.h"
#include "nativekit_ui_layout.h"
#include "nativekit_window.h"

#if defined(__EMSCRIPTEN__) || defined(__ANDROID__)
#include <GLES3/gl3.h>
#elif defined(__APPLE__)
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#elif defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <GL/gl.h>
#else
#include <GL/gl.h>
#endif

#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#ifndef NKUI_TEST_FONT_PATH
#error NKUI_TEST_FONT_PATH is required
#endif

namespace {

void write_u32(std::vector<uint8_t> &bytes, std::size_t offset, uint32_t value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_i32(std::vector<uint8_t> &bytes, std::size_t offset, int32_t value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_float(std::vector<uint8_t> &bytes, std::size_t offset, float value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

void write_color(std::vector<uint8_t> &bytes, std::size_t offset, float red, float green,
                 float blue, float alpha) {
    write_float(bytes, offset, red);
    write_float(bytes, offset + 4, green);
    write_float(bytes, offset + 8, blue);
    write_float(bytes, offset + 12, alpha);
}

template <class T> void append_bytes(std::vector<uint8_t> &bytes, const T &value) {
    const std::size_t offset = bytes.size();
    bytes.resize(offset + sizeof(value));
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

std::vector<uint8_t> transaction(float width, float height) {
    constexpr uint32_t node_count = 3;
    constexpr std::size_t string_offset =
        NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES * node_count;
    const char text[] = "Press";
    std::vector<uint8_t> bytes(string_offset + sizeof(text) - 1);
    write_u32(bytes, 0, NKUI_LAYOUT_TRANSACTION_VERSION);
    write_u32(bytes, 4, node_count);
    write_u32(bytes, 8, NKUI_LAYOUT_NODE_RECORD_BYTES);
    write_u32(bytes, 12, static_cast<uint32_t>(string_offset));

    for (uint32_t index = 0; index < node_count; ++index) {
        const std::size_t offset = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
                                   static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_A_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_TRANSFORM_D_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_WIDTH_GROW_WEIGHT_OFFSET, 1.0f);
        write_float(bytes, offset + NKUI_LAYOUT_NODE_HEIGHT_GROW_WEIGHT_OFFSET, 1.0f);
        write_u32(bytes, offset + NKUI_LAYOUT_NODE_FLAGS_OFFSET, NKUI_LAYOUT_NODE_VISIBLE);
    }

    const auto record = [&](uint32_t index) {
        return NKUI_LAYOUT_TRANSACTION_HEADER_BYTES +
               static_cast<std::size_t>(index) * NKUI_LAYOUT_NODE_RECORD_BYTES;
    };

    // Root box painted with a solid background.
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_ID_OFFSET, 1);
    write_i32(bytes, record(0) + NKUI_LAYOUT_NODE_PARENT_OFFSET, -1);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, width);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, height);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
    write_color(bytes, record(0) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.1f, 0.1f, 0.1f, 1.0f);
    write_float(bytes, record(0) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(0) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET,
              static_cast<uint32_t>(string_offset));

    // Button child with an offset box and background.
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_ID_OFFSET, 2);
    write_i32(bytes, record(1) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 0);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_BOX);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 160.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIXED);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 64.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET, 12.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET, 20.0f);
    write_color(bytes, record(1) + NKUI_LAYOUT_NODE_BACKGROUND_OFFSET, 0.2f, 0.5f, 0.9f, 1.0f);
    write_float(bytes, record(1) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 16.0f);
    write_u32(bytes, record(1) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET,
              static_cast<uint32_t>(string_offset));

    // Text child.
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_ID_OFFSET, 3);
    write_i32(bytes, record(2) + NKUI_LAYOUT_NODE_PARENT_OFFSET, 1);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_TEXT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_WIDTH_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_HEIGHT_SIZING_OFFSET, NKUI_LAYOUT_SIZING_FIT);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_DIRECTION_OFFSET,
              NKUI_LAYOUT_DIRECTION_TOP_TO_BOTTOM);
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_OFFSET_OFFSET,
              static_cast<uint32_t>(string_offset));
    write_u32(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_LENGTH_OFFSET, sizeof(text) - 1);
    write_color(bytes, record(2) + NKUI_LAYOUT_NODE_TEXT_COLOR_OFFSET, 1.0f, 1.0f, 1.0f, 1.0f);
    write_float(bytes, record(2) + NKUI_LAYOUT_NODE_FONT_SIZE_OFFSET, 18.0f);

    std::memcpy(bytes.data() + string_offset, text, sizeof(text) - 1);
    return bytes;
}

} // namespace

int main() {
    nk_init_options init{};
    init.struct_size = sizeof(init);
    init.api_version = NK_API_VERSION;
    if (nk_init(&init) != NK_OK) {
        std::fprintf(stderr, "nk_init failed\n");
        return 1;
    }

    constexpr int width = 256;
    constexpr int height = 192;
    nk_window_options window_options{};
    window_options.struct_size = sizeof(window_options);
    window_options.width = width;
    window_options.height = height;
    window_options.title = "NativeKit layout session render";
    nk_window window = 0;
    if (nk_window_create(&window_options, &window) != NK_OK) {
        std::fprintf(stderr, "window create failed\n");
        return 2;
    }

    nk_surface_options surface_options{};
    surface_options.struct_size = sizeof(surface_options);
    surface_options.api = nkgpu_default_graphics_api();
    surface_options.flags = NK_SURFACE_STENCIL;
    if (surface_options.api == NK_GRAPHICS_OPENGL)
        surface_options.flags |= NK_SURFACE_FORWARD_COMPATIBLE;
    surface_options.major_version = 3;
    if (surface_options.api == NK_GRAPHICS_OPENGL)
        surface_options.minor_version = 3;
    surface_options.width = width;
    surface_options.height = height;
    nk_surface surface = 0;
    if (nk_surface_create(window, &surface_options, &surface) != NK_OK) {
        std::fprintf(stderr, "surface create failed\n");
        return 3;
    }

    nkui_resource fonts{};
    nkui_renderer renderer{};
    nkui_display_list list{};
    nkui_layout_session session{};
    if (nkui_font_collection_create(&fonts) != NKUI_OK ||
        nkui_font_collection_add(fonts, NKUI_TEST_FONT_PATH, NKUI_FONT_FAMILY_DEFAULT) != NKUI_OK ||
        nkui_renderer_create(&renderer) != NKUI_OK || nkui_display_list_create(&list) != NKUI_OK ||
        nkui_layout_session_create(&session) != NKUI_OK ||
        nkui_layout_session_set_font_collection(session, fonts) != NKUI_OK) {
        std::fprintf(stderr, "resource setup failed\n");
        return 4;
    }

    bool ready = false;
    int framebuffer_width = 0;
    int framebuffer_height = 0;
    for (int attempt = 0; attempt < 5000 && !ready; ++attempt) {
        nk_event event{};
        event.struct_size = sizeof(event);
        if (nk_poll_event(&event) == NK_OK && event.kind == NK_EVENT_SURFACE_READY &&
            event.source == surface) {
            ready = nk_surface_make_current(surface) == NK_OK &&
                    nk_surface_get_framebuffer_size(surface, &framebuffer_width,
                                                    &framebuffer_height) == NK_OK;
        }
        nk_event_release(&event);
        if (!ready)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!ready) {
        std::fprintf(stderr, "surface never became ready\n");
        return 5;
    }

    const float pixel_scale = 1.0f;
    const nkui_frame_info frame_info{sizeof(frame_info),
                                     framebuffer_width / pixel_scale,
                                     framebuffer_height / pixel_scale,
                                     framebuffer_width,
                                     framebuffer_height,
                                     pixel_scale};

    int result = 0;

    /*
     * A session that has never been successfully submitted has no layout to
     * render; the render entry point must reject it as an invalid handle
     * rather than rendering an empty frame. This is the failure mode that a
     * malformed transaction produces: submit fails, the session stays
     * unsubmitted, and the render call then reports NKUI_ERROR_INVALID_HANDLE.
     */
    const nkui_result unsubmitted_render =
        nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0);
    if (unsubmitted_render != NKUI_ERROR_INVALID_HANDLE) {
        std::fprintf(stderr, "unsubmitted session render returned %d, expected %d\n",
                     static_cast<int>(unsubmitted_render),
                     static_cast<int>(NKUI_ERROR_INVALID_HANDLE));
        result = 13;
    }

    const nkui_result display_list_result =
        nkui_renderer_render_frame(renderer, list, surface, &frame_info);
    if (display_list_result != NKUI_OK)
        result = 10;

    const auto bytes =
        transaction(framebuffer_width / pixel_scale, framebuffer_height / pixel_scale);
    nkui_layout_frame_input frame{sizeof(frame), framebuffer_width / pixel_scale,
                                  framebuffer_height / pixel_scale, 1.0f / 60.0f};
    const nkui_result submit_result = nkui_layout_session_submit(
        session, bytes.data(), static_cast<uint32_t>(bytes.size()), &frame);
    if (submit_result != NKUI_OK) {
        std::fprintf(stderr, "session submit returned %d\n", static_cast<int>(submit_result));
        result = 11;
    }

    if (!result &&
        nkui_layout_session_set_cache_policy(session, 1, NKUI_LAYOUT_CACHE_RASTER) != NKUI_OK)
        result = 12;

    nkui_renderer_stats root_cache_first{};
    nkui_renderer_stats root_cache_repeated{};
    nkui_renderer_stats root_cache_moved{};
    if (!result) {
        const nkui_result session_result =
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0);
        if (session_result != NKUI_OK) {
            std::fprintf(stderr, "session render returned %d\n", static_cast<int>(session_result));
            result = 13;
        } else if (nkui_renderer_get_stats(renderer, &root_cache_first) != NKUI_OK ||
                   root_cache_first.raster_cache_misses == 0 ||
                   root_cache_first.raster_cache_entries == 0 ||
                   root_cache_first.raster_cache_bytes == 0) {
            std::fprintf(stderr, "initial raster cache render did not populate a cache entry\n");
            result = 14;
        }
    }

    if (!result) {
        const auto started = std::chrono::steady_clock::now();
        constexpr int repeated_frames = 32;
        for (int repeat = 0; repeat < repeated_frames && !result; ++repeat) {
            if (nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) !=
                NKUI_OK)
                result = 15;
        }
        const auto elapsed = std::chrono::steady_clock::now() - started;
        if (!result && nkui_renderer_get_stats(renderer, &root_cache_repeated) != NKUI_OK)
            result = 16;
        if (!result && root_cache_repeated.raster_cache_hits <
                           root_cache_first.raster_cache_hits + repeated_frames) {
            std::fprintf(stderr, "repeated raster frames did not hit the cache: %llu -> %llu\n",
                         static_cast<unsigned long long>(root_cache_first.raster_cache_hits),
                         static_cast<unsigned long long>(root_cache_repeated.raster_cache_hits));
            result = 17;
        }
        if (!result) {
            const auto elapsed_ns =
                std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
            std::printf("raster cache repeat: %d frames, %llu hits, %lld ns/frame\n",
                         repeated_frames,
                         static_cast<unsigned long long>(root_cache_repeated.raster_cache_hits -
                                                         root_cache_first.raster_cache_hits),
                         static_cast<long long>(elapsed_ns / repeated_frames));
        }
    }

    /* A visual translation changes only the composite placement of a cached
     * subtree. It must not force the subtree to be rasterized again. */
    if (!result) {
        auto moved = bytes;
        const std::size_t root_record = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES;
        write_float(moved, root_record + NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET, 32.0f);
        write_float(moved, root_record + NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET, 16.0f);
        if (nkui_layout_session_submit(session, moved.data(), static_cast<uint32_t>(moved.size()),
                                       &frame) != NKUI_OK ||
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) !=
                NKUI_OK ||
            nkui_renderer_get_stats(renderer, &root_cache_moved) != NKUI_OK ||
            root_cache_moved.raster_cache_misses != root_cache_repeated.raster_cache_misses ||
            root_cache_moved.raster_cache_hits <= root_cache_repeated.raster_cache_hits) {
            std::fprintf(stderr, "translated raster subtree missed its retained cache\n");
            result = 18;
        }
    }

    if (!result &&
        nkui_layout_session_submit(session, bytes.data(), static_cast<uint32_t>(bytes.size()),
                                   &frame) != NKUI_OK)
        result = 19;

    if (!result &&
        nkui_layout_session_set_cache_policy(session, 1, NKUI_LAYOUT_CACHE_NONE) != NKUI_OK)
        result = 20;

    /*
     * The same session renders across pixel scales. Each frame clears first,
     * so reading a corner pixel outside the button proves the layout actually
     * reached the framebuffer instead of the call merely returning OK.
     */
    if (!result) {
        constexpr float scales[] = {1.0f, 1.25f, 2.0f};
        for (float scale : scales) {
            const nkui_frame_info scaled_info{sizeof(scaled_info),        framebuffer_width / scale,
                                              framebuffer_height / scale, framebuffer_width,
                                              framebuffer_height,         scale};
            const nkui_result scaled_result =
                nkui_layout_session_render_frame(renderer, session, surface, &scaled_info, 0);
            if (scaled_result != NKUI_OK) {
                std::fprintf(stderr, "session render at scale %g returned %d\n",
                             static_cast<double>(scale), static_cast<int>(scaled_result));
                result = 14;
                break;
            }
            uint8_t corner[4]{};
            glReadPixels(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
            if (corner[0] != corner[1] || corner[1] != corner[2] || corner[3] != 255 ||
                corner[0] < 10 || corner[0] > 60) {
                std::fprintf(stderr,
                             "session render at scale %g left corner pixel "
                             "(%u,%u,%u,%u)\n",
                             static_cast<double>(scale), corner[0], corner[1], corner[2],
                             corner[3]);
                result = 21;
                break;
            }
        }
    }

    /* Compositing over the existing frame keeps the path out of the clear-first
     * branch and must still succeed. */
    if (!result &&
        nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 1) != NKUI_OK)
        result = 22;

    /*
     * Custom-visual nodes render through the compiler's embedded-plan path
     * instead of plain primitives, so drive one custom paint and confirm its
     * content reaches the node's bounds.
     */
    if (!result) {
        constexpr std::size_t second_record =
            NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
        auto custom_tree =
            transaction(framebuffer_width / pixel_scale, framebuffer_height / pixel_scale);
        write_u32(custom_tree, second_record + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET,
                  NKUI_LAYOUT_VISUAL_CUSTOM);

        const nkui_path_element rectangle[] = {
            {NKUI_PATH_MOVE_TO, {0.0f, 0.0f}},
            {NKUI_PATH_LINE_TO, {160.0f, 0.0f}},
            {NKUI_PATH_LINE_TO, {160.0f, 64.0f}},
            {NKUI_PATH_LINE_TO, {0.0f, 64.0f}},
            {NKUI_PATH_CLOSE, {}},
        };
        nkui_resource custom_paint{};
        nkui_resource custom_path{};
        nkui_display_list custom_list{};
        const auto make_custom_commands = [&](float x, float y) {
            std::vector<uint8_t> commands;
            append_bytes(commands,
                         nkui_resource_command{{NKUI_COMMAND_SET_PAINT, NKUI_COMMAND_VERSION,
                                                sizeof(nkui_resource_command)},
                                               custom_paint});
            append_bytes(commands,
                         nkui_transform_command{{NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION,
                                                 sizeof(nkui_transform_command)},
                                                {1.0f, 0.0f, 0.0f, 1.0f, x, y}});
            append_bytes(commands,
                         nkui_resource_command{{NKUI_COMMAND_DRAW_PATH, NKUI_COMMAND_VERSION,
                                                sizeof(nkui_resource_command)},
                                               custom_path});
            return commands;
        };
        if (nkui_paint_create_solid({1.0f, 0.0f, 0.0f, 1.0f}, &custom_paint) != NKUI_OK ||
            nkui_path_create(rectangle, 5, &custom_path) != NKUI_OK ||
            nkui_display_list_create(&custom_list) != NKUI_OK)
            result = 22;
        if (!result) {
            /* Custom paint commands are node-local; the layout session applies
             * the node's position when embedding the retained list. */
            const auto custom_commands = make_custom_commands(0.0f, 0.0f);
            if (nkui_display_list_submit(custom_list, custom_commands.data(),
                                         static_cast<uint32_t>(custom_commands.size())) !=
                    NKUI_OK ||
                nkui_layout_session_submit(session, custom_tree.data(),
                                           static_cast<uint32_t>(custom_tree.size()),
                                           &frame) != NKUI_OK ||
                nkui_layout_session_set_custom_paint(session, 2, custom_list) != NKUI_OK ||
                nkui_layout_session_set_cache_policy(session, 2, NKUI_LAYOUT_CACHE_RASTER) !=
                    NKUI_OK)
                result = 23;
        }
        nkui_renderer_stats custom_cache_first{};
        nkui_renderer_stats custom_cache_repeated{};
        nkui_renderer_stats custom_cache_scaled{};
        nkui_renderer_stats custom_cache_pressure{};
        if (!result &&
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) !=
                NKUI_OK)
            result = 24;
        if (!result &&
            (nkui_renderer_get_stats(renderer, &custom_cache_first) != NKUI_OK ||
             custom_cache_first.raster_cache_misses <= root_cache_moved.raster_cache_misses ||
             custom_cache_first.raster_cache_entries == 0 ||
             custom_cache_first.raster_cache_bytes == 0 ||
             custom_cache_first.custom_paint_nodes == 0)) {
            std::fprintf(stderr, "custom paint did not compile and populate the raster cache\n");
            result = 25;
        }
        if (!result) {
            /*
             * Node 2 sits at (12, 20) with a 160x64 box, so its custom paint
             * covers framebuffer x 12..172, y (bottom-up) 108..172.
             */
            std::array<uint8_t, 20 * 20 * 4> block{};
            glReadPixels(40, 120, 20, 20, GL_RGBA, GL_UNSIGNED_BYTE, block.data());
            int red = 0;
            for (std::size_t pixel = 0; pixel < 20 * 20; ++pixel) {
                const uint8_t *rgba = block.data() + pixel * 4;
                if (rgba[0] > 200 && rgba[1] < 60 && rgba[2] < 60 && rgba[3] == 255)
                    ++red;
            }
            if (red < 20 * 20) {
                std::fprintf(stderr, "custom paint covered %d of %d sampled pixels\n", red,
                             20 * 20);
                result = 26;
            }
        }

        if (!result) {
            constexpr int repeated_frames = 24;
            const auto started = std::chrono::steady_clock::now();
            for (int repeat = 0; repeat < repeated_frames && !result; ++repeat) {
                if (nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) !=
                    NKUI_OK)
                    result = 27;
            }
            const auto elapsed = std::chrono::steady_clock::now() - started;
            if (!result && nkui_renderer_get_stats(renderer, &custom_cache_repeated) != NKUI_OK)
                result = 28;
            if (!result && custom_cache_repeated.raster_cache_hits <
                               custom_cache_first.raster_cache_hits + repeated_frames) {
                std::fprintf(stderr, "custom raster frames did not hit the cache: %llu -> %llu\n",
                             static_cast<unsigned long long>(custom_cache_first.raster_cache_hits),
                             static_cast<unsigned long long>(
                                 custom_cache_repeated.raster_cache_hits));
                result = 29;
            }
            if (!result && custom_cache_repeated.custom_paint_nodes !=
                               custom_cache_first.custom_paint_nodes) {
                std::fprintf(stderr,
                             "unchanged custom paint was recompiled: %llu -> %llu\n",
                             static_cast<unsigned long long>(custom_cache_first.custom_paint_nodes),
                             static_cast<unsigned long long>(
                                 custom_cache_repeated.custom_paint_nodes));
                result = 36;
            }
            if (!result) {
                const auto elapsed_ns =
                    std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
                std::printf("custom raster repeat: %d frames, %llu hits, %llu compiled plans, "
                            "%lld ns/frame\n",
                             repeated_frames,
                             static_cast<unsigned long long>(
                                 custom_cache_repeated.raster_cache_hits -
                                 custom_cache_first.raster_cache_hits),
                             static_cast<unsigned long long>(
                                 custom_cache_repeated.custom_paint_nodes -
                                 custom_cache_first.custom_paint_nodes),
                             static_cast<long long>(elapsed_ns / repeated_frames));
            }
        }

        /* A device-scale change produces a different physical raster, while
         * returning to the original scale can reuse its retained entry. */
        if (!result) {
            constexpr float churn_scales[] = {1.25f, 2.0f, 1.0f};
            for (float scale : churn_scales) {
                const nkui_frame_info scaled_info{
                    sizeof(scaled_info), framebuffer_width / scale, framebuffer_height / scale,
                    framebuffer_width, framebuffer_height, scale};
                if (nkui_layout_session_render_frame(renderer, session, surface, &scaled_info, 0) !=
                    NKUI_OK) {
                    result = 30;
                    break;
                }
            }
            if (!result && nkui_renderer_get_stats(renderer, &custom_cache_scaled) != NKUI_OK)
                result = 31;
            if (!result && custom_cache_scaled.raster_cache_misses <
                               custom_cache_repeated.raster_cache_misses + 2) {
                std::fprintf(stderr, "device-scale churn did not invalidate raster dimensions\n");
                result = 32;
            }
        }

        /* Feed more unique content versions than the bounded cache can retain
         * and verify that capacity pressure evicts entries without allowing
         * unbounded GPU memory growth. */
        if (!result) {
            constexpr int pressure_frames = 160;
            for (int pressure = 0; pressure < pressure_frames && !result; ++pressure) {
                const auto pressure_commands =
                    make_custom_commands(20.0f + static_cast<float>(pressure), 20.0f);
                if (nkui_display_list_submit(custom_list, pressure_commands.data(),
                                             static_cast<uint32_t>(pressure_commands.size())) !=
                    NKUI_OK ||
                    nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) !=
                        NKUI_OK)
                    result = 33;
            }
            if (!result && nkui_renderer_get_stats(renderer, &custom_cache_pressure) != NKUI_OK)
                result = 34;
            if (!result &&
                (custom_cache_pressure.raster_cache_misses <
                     custom_cache_scaled.raster_cache_misses + pressure_frames ||
                 custom_cache_pressure.custom_paint_nodes <
                     custom_cache_scaled.custom_paint_nodes + pressure_frames ||
                 custom_cache_pressure.raster_cache_entries > 128 ||
                 custom_cache_pressure.raster_cache_bytes > 64u * 1024u * 1024u)) {
                std::fprintf(stderr,
                             "raster cache pressure exceeded its bounds: misses=%llu entries=%llu "
                             "bytes=%llu\n",
                             static_cast<unsigned long long>(
                                 custom_cache_pressure.raster_cache_misses),
                             static_cast<unsigned long long>(
                                 custom_cache_pressure.raster_cache_entries),
                             static_cast<unsigned long long>(
                                 custom_cache_pressure.raster_cache_bytes));
                result = 35;
            }
        }
        /*
         * A custom-paint node that draws a retained TextLayout (the path
         * TextField/TextArea use for their editable content) must paint the
         * layout's foreground override and base color, including retained snapshots.
         * Regression coverage for the layout-session owned/sealed glyph
         * snapshot silently defaulting to opaque white.
         */
        nkui_resource text_layout{};
        nkui_display_list text_list{};
        const nkui_text_color_range first_letter{0, 1, {0.0f, 0.85f, 0.0f, 1.0f}};
        if (!result) {
            if (nkui_text_layout_create(fonts, "Hg", 140.0f, 40.0f, &text_layout) != NKUI_OK ||
                nkui_text_layout_set_color_ranges(text_layout, &first_letter, 1) != NKUI_OK ||
                nkui_text_layout_set_color(text_layout, {0.0f, 0.0f, 0.85f, 1.0f}) != NKUI_OK ||
                nkui_display_list_create(&text_list) != NKUI_OK)
                result = 37;
        }
        if (!result) {
            // custom_tree's node index 2 is the "Press" label rendered white
            // (transaction()'s own NKUI_LAYOUT_NODE_TEXT_COLOR_OFFSET). It is
            // still a normal child of the reused custom node and would
            // overlap the sampled region, so hide it for this sub-test.
            auto text_tree = custom_tree;
            constexpr std::size_t third_record =
                NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + 2 * NKUI_LAYOUT_NODE_RECORD_BYTES;
            write_u32(text_tree, third_record + NKUI_LAYOUT_NODE_FLAGS_OFFSET, 0);
            std::vector<uint8_t> text_commands;
            append_bytes(text_commands,
                        nkui_transform_command{{NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION,
                                                sizeof(nkui_transform_command)},
                                               {1.0f, 0.0f, 0.0f, 1.0f, 8.0f, 45.0f}});
            append_bytes(text_commands,
                        nkui_draw_rect_command{{NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION,
                                                sizeof(nkui_draw_rect_command)},
                                               text_layout, 0.0f, 0.0f, 0.0f, 0.0f});
            if (nkui_display_list_submit(text_list, text_commands.data(),
                                         static_cast<uint32_t>(text_commands.size())) != NKUI_OK ||
                nkui_layout_session_submit(session, text_tree.data(),
                                           static_cast<uint32_t>(text_tree.size()),
                                           &frame) != NKUI_OK ||
                nkui_layout_session_set_custom_paint(session, 2, text_list) != NKUI_OK ||
                nkui_layout_session_set_cache_policy(session, 2, NKUI_LAYOUT_CACHE_RASTER) !=
                    NKUI_OK)
                result = 38;
        }
        if (!result &&
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK)
            result = 39;
        if (!result) {
            /* Node 2 again covers framebuffer x 12..172, y (bottom-up) 108..172. */
            std::array<uint8_t, 160 * 64 * 4> block{};
            glReadPixels(12, 108, 160, 64, GL_RGBA, GL_UNSIGNED_BYTE, block.data());
            int best_green = -1;
            int blue_pixels = 0;
            uint8_t best_rgba[4] = {0, 0, 0, 0};
            for (std::size_t pixel = 0; pixel < 160 * 64; ++pixel) {
                const uint8_t *rgba = block.data() + pixel * 4;
                if (rgba[2] > 150 && rgba[0] < 80 && rgba[1] < 80)
                    ++blue_pixels;
                if (rgba[1] > best_green) {
                    best_green = rgba[1];
                    std::memcpy(best_rgba, rgba, 4);
                }
            }
            // Opaque white glyphs (the untinted-snapshot bug) leave red and blue as high
            // as green; a correctly tinted green layout keeps them low.
            if (best_green < 150 || best_rgba[0] > 80 || best_rgba[2] > 80 || blue_pixels == 0) {
                std::fprintf(stderr,
                             "custom-paint text layout did not render its set color: "
                             "peak rgba = %d,%d,%d,%d\n",
                             best_rgba[0], best_rgba[1], best_rgba[2], best_rgba[3]);
                result = 40;
            }
        }
        // Re-render to ensure the retained raster cache keeps the tinted color
        // on frames that reuse the sealed plan instead of recompiling it.
        if (!result &&
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK)
            result = 41;
        if (!result) {
            std::array<uint8_t, 160 * 64 * 4> block{};
            glReadPixels(12, 108, 160, 64, GL_RGBA, GL_UNSIGNED_BYTE, block.data());
            int best_green = -1;
            int blue_pixels = 0;
            uint8_t best_rgba[4] = {0, 0, 0, 0};
            for (std::size_t pixel = 0; pixel < 160 * 64; ++pixel) {
                const uint8_t *rgba = block.data() + pixel * 4;
                if (rgba[2] > 150 && rgba[0] < 80 && rgba[1] < 80)
                    ++blue_pixels;
                if (rgba[1] > best_green) {
                    best_green = rgba[1];
                    std::memcpy(best_rgba, rgba, 4);
                }
            }
            if (best_green < 150 || best_rgba[0] > 80 || best_rgba[2] > 80 || blue_pixels == 0) {
                std::fprintf(stderr,
                             "custom-paint text layout lost its set color on a cached repaint: "
                             "peak rgba = %d,%d,%d,%d\n",
                             best_rgba[0], best_rgba[1], best_rgba[2], best_rgba[3]);
                result = 42;
            }
        }
        // Recolor a retained layout after the node has a live raster cache.
        const nkui_text_color_range recolored_letter{0, 1, {0.85f, 0.0f, 0.0f, 1.0f}};
        if (!result && (nkui_text_layout_set_color_ranges(text_layout, &recolored_letter, 1) != NKUI_OK ||
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK))
            result = 43;
        if (!result) {
            std::array<uint8_t, 160 * 64 * 4> block{};
            glReadPixels(12, 108, 160, 64, GL_RGBA, GL_UNSIGNED_BYTE, block.data());
            int red_pixels = 0;
            int green_pixels = 0;
            for (std::size_t pixel = 0; pixel < 160 * 64; ++pixel) {
                const uint8_t *rgba = block.data() + pixel * 4;
                if (rgba[0] > 150 && rgba[1] < 80 && rgba[2] < 80)
                    ++red_pixels;
                if (rgba[1] > 150 && rgba[0] < 80 && rgba[2] < 80)
                    ++green_pixels;
            }
            if (!red_pixels || green_pixels) {
                std::fprintf(stderr, "cached text recolor: red=%d green=%d\n", red_pixels, green_pixels);
                result = 44;
            }
        }
        if (!result && (nkui_text_layout_set_text(text_layout, "Hg") != NKUI_OK ||
            nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK))
            result = 45;
        if (!result) {
            std::array<uint8_t, 160 * 64 * 4> block{};
            glReadPixels(12, 108, 160, 64, GL_RGBA, GL_UNSIGNED_BYTE, block.data());
            int blue_pixels = 0;
            int stale_pixels = 0;
            for (std::size_t pixel = 0; pixel < 160 * 64; ++pixel) {
                const uint8_t *rgba = block.data() + pixel * 4;
                if (rgba[2] > 150 && rgba[0] < 80 && rgba[1] < 80)
                    ++blue_pixels;
                if (rgba[0] > 150 || rgba[1] > 150)
                    ++stale_pixels;
            }
            if (!blue_pixels || stale_pixels)
                result = 46;
        }
        // A wrapped custom-paint layout must cache each visible text row. An
        // edit in its first row should miss that row while other rows hit.
        nkui_resource wrapped_rows{};
        if (!result) {
            const std::string word(512, 'a');
            nkui_text_style row_style{sizeof(row_style), NKUI_FONT_FAMILY_DEFAULT, 18.0f, 0.0f};
            nkui_paragraph_style row_paragraph{sizeof(row_paragraph), 24.0f,
                NKUI_TEXT_WRAP_WORD_CHARACTER, NKUI_TEXT_ALIGN_START, NKUI_TEXT_DIRECTION_AUTO};
            if (nkui_text_layout_create_styled(fonts, word.c_str(), 140.0f, &row_style,
                                               &row_paragraph, &wrapped_rows) != NKUI_OK)
                result = 47;
        }
        if (!result && (nkui_text_layout_set_text(wrapped_rows, "Hg\nHg\nHg\nHg") != NKUI_OK ||
            nkui_text_layout_set_color(wrapped_rows, {0.0f, 0.0f, 0.85f, 1.0f}) != NKUI_OK)) result = 61;
        if (!result) {
            std::vector<uint8_t> initial_commands;
            append_bytes(initial_commands, nkui_draw_rect_command{
                {NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION, sizeof(nkui_draw_rect_command)},
                wrapped_rows, 0, 0, 0, 0});
            if (nkui_display_list_submit(text_list, initial_commands.data(), initial_commands.size()) != NKUI_OK)
                result = 61;
        }
        // Fractionally moving text must avoid one-use row textures. Once it
        // stops, cached pixels must match the direct frame and then be reused.
        if (!result && nkui_layout_session_set_cache_policy(session, 2, NKUI_LAYOUT_CACHE_NONE) != NKUI_OK)
            result = 61;
        for (float zoom : {1.0f, 1.1f, 1.2f, 1.5f, 2.0f}) {
            if (result) break;
            const nkui_frame_info moving_info{sizeof(moving_info), framebuffer_width / zoom,
                framebuffer_height / zoom, framebuffer_width, framebuffer_height, zoom};
            nkui_renderer_stats moving{}, stationary{}, cached{};
            std::vector<uint8_t> direct_pixels(framebuffer_width * framebuffer_height * 4);
            for (float y : {0.25f, 1.5f, 2.75f}) {
                if (result) break;
                std::vector<uint8_t> moving_commands;
                append_bytes(moving_commands, nkui_transform_command{
                    {NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION, sizeof(nkui_transform_command)},
                    {1.0f, 0.0f, 0.0f, 1.0f, 8.0f, y}});
                append_bytes(moving_commands, nkui_draw_rect_command{
                    {NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION, sizeof(nkui_draw_rect_command)},
                    wrapped_rows, 0, 0, 0, 0});
                nkui_renderer_stats before{};
                if (nkui_renderer_get_stats(renderer, &before) != NKUI_OK ||
                    nkui_display_list_submit(text_list, moving_commands.data(), moving_commands.size()) != NKUI_OK ||
                    nkui_layout_session_render_frame(renderer, session, surface, &moving_info, 0) != NKUI_OK ||
                    nkui_renderer_get_stats(renderer, &moving) != NKUI_OK ||
                    moving.raster_cache_misses != before.raster_cache_misses) result = 61;
            }
            if (!result) {
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA, GL_UNSIGNED_BYTE, direct_pixels.data());
                if (nkui_layout_session_render_frame(renderer, session, surface, &moving_info, 0) != NKUI_OK ||
                    nkui_renderer_get_stats(renderer, &stationary) != NKUI_OK ||
                    stationary.raster_cache_misses <= moving.raster_cache_misses) result = 62;
                std::vector<uint8_t> cached_pixels(direct_pixels.size());
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA, GL_UNSIGNED_BYTE, cached_pixels.data());
                if (cached_pixels != direct_pixels) {
                    int maximum_difference = 0; size_t changed = 0;
                    for (size_t index = 0; index < cached_pixels.size(); ++index) {
                        const int difference = std::abs(int(cached_pixels[index]) - int(direct_pixels[index]));
                        maximum_difference = std::max(maximum_difference, difference);
                        changed += difference != 0;
                    }
                    std::fprintf(stderr, "row cache pixel difference zoom=%g max=%d changed=%zu\n", zoom, maximum_difference, changed);
                    result = 63;
                }
                if (!result && (nkui_layout_session_render_frame(renderer, session, surface, &moving_info, 0) != NKUI_OK ||
                    nkui_renderer_get_stats(renderer, &cached) != NKUI_OK ||
                    cached.raster_cache_misses != stationary.raster_cache_misses ||
                    cached.raster_cache_hits <= stationary.raster_cache_hits)) result = 64;
                // Binary-exact transforms preserve the subpixel phase under
                // whole-pixel movement. Decimal zoom can change it by an ulp;
                // a conservative cache miss there is valid.
                const bool exact_translation = zoom == 1.0f || zoom == 1.5f || zoom == 2.0f;
                std::vector<uint8_t> translated_commands;
                append_bytes(translated_commands, nkui_transform_command{
                    {NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION, sizeof(nkui_transform_command)},
                    {1.0f, 0.0f, 0.0f, 1.0f, 8.0f, 12.75f}});
                append_bytes(translated_commands, nkui_draw_rect_command{
                    {NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION, sizeof(nkui_draw_rect_command)},
                    wrapped_rows, 0, 0, 0, 0});
                nkui_renderer_stats translated{};
                if (!result && (nkui_display_list_submit(text_list, translated_commands.data(),
                        static_cast<uint32_t>(translated_commands.size())) != NKUI_OK ||
                    nkui_layout_session_render_frame(renderer, session, surface, &moving_info, 0) != NKUI_OK ||
                    nkui_renderer_get_stats(renderer, &translated) != NKUI_OK ||
                    (exact_translation && (translated.raster_cache_misses != cached.raster_cache_misses ||
                    translated.raster_cache_hits <= cached.raster_cache_hits)))) result = 65;
                if (!result) std::printf("PASS: moving/stationary row rendering at zoom=%g\n", zoom);
            }
        }
        if (std::getenv("NKUI_MOVING_ROWS_TEST_ONLY")) return result;
        const std::string restored_word(512, 'a');
        if (!result && (nkui_text_layout_set_text(wrapped_rows, restored_word.c_str()) != NKUI_OK ||
            nkui_text_layout_set_color(wrapped_rows, {1, 1, 1, 1}) != NKUI_OK ||
            nkui_layout_session_set_cache_policy(session, 2, NKUI_LAYOUT_CACHE_RASTER) != NKUI_OK)) result = 61;
        if (!result) {
            std::vector<uint8_t> row_commands;
            append_bytes(row_commands,
                nkui_transform_command{{NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION,
                                        sizeof(nkui_transform_command)},
                                       {1.0f, 0.0f, 0.0f, 1.0f, 8.0f, 4.0f}});
            append_bytes(row_commands,
                nkui_draw_rect_command{{NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION,
                                        sizeof(nkui_draw_rect_command)},
                                       wrapped_rows, 0.0f, 0.0f, 0.0f, 0.0f});
            nkui_renderer_stats before_rows{}, first_rows{}, repeated_rows{}, edited_rows{};
            if (nkui_display_list_submit(text_list, row_commands.data(),
                                         static_cast<uint32_t>(row_commands.size())) != NKUI_OK ||
                // First placement draws directly; the repeat can populate row textures.
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &before_rows) != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &first_rows) != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &repeated_rows) != NKUI_OK ||
                nkui_text_layout_edit(wrapped_rows, 4, 5, "e") != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &edited_rows) != NKUI_OK) {
                result = 48;
            } else {
                std::printf("wrapped row raster cache: first misses=%llu, repeat hits=%llu, edited hits=%llu misses=%llu\n",
                    static_cast<unsigned long long>(first_rows.raster_cache_misses - before_rows.raster_cache_misses),
                    static_cast<unsigned long long>(repeated_rows.raster_cache_hits - first_rows.raster_cache_hits),
                    static_cast<unsigned long long>(edited_rows.raster_cache_hits - repeated_rows.raster_cache_hits),
                    static_cast<unsigned long long>(edited_rows.raster_cache_misses - repeated_rows.raster_cache_misses));
                std::printf("wrapped row draws: first=%llu repeat=%llu edited=%llu\n",
                    static_cast<unsigned long long>(first_rows.gpu_draw_calls - before_rows.gpu_draw_calls),
                    static_cast<unsigned long long>(repeated_rows.gpu_draw_calls - first_rows.gpu_draw_calls),
                    static_cast<unsigned long long>(edited_rows.gpu_draw_calls - repeated_rows.gpu_draw_calls));
                if (edited_rows.gpu_draw_calls - repeated_rows.gpu_draw_calls >=
                        first_rows.gpu_draw_calls - before_rows.gpu_draw_calls ||
                    edited_rows.gpu_draw_calls - repeated_rows.gpu_draw_calls <=
                        repeated_rows.gpu_draw_calls - first_rows.gpu_draw_calls)
                    result = 49;
                if (first_rows.raster_cache_misses < before_rows.raster_cache_misses + 2 ||
                    repeated_rows.raster_cache_hits < first_rows.raster_cache_hits + 2 ||
                    edited_rows.raster_cache_hits < repeated_rows.raster_cache_hits + 2 ||
                    edited_rows.raster_cache_misses != repeated_rows.raster_cache_misses + 2)
                    result = 48;
            }
            // Unicode forces a fresh native layout but unchanged rows must
            // retain their raster identity after glyph equivalence is checked.
            nkui_renderer_stats unicode_rows{};
            if (!result && (nkui_text_layout_edit(wrapped_rows, 4, 5, "é") != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &unicode_rows) != NKUI_OK))
                result = 50;
            if (!result && (unicode_rows.raster_cache_hits < edited_rows.raster_cache_hits + 2 ||
                unicode_rows.raster_cache_misses != edited_rows.raster_cache_misses + 2)) {
                std::fprintf(stderr, "Unicode row edit rebuilt unchanged rasters\n");
                result = 51;
            }
            std::vector<uint8_t> original_pixels(framebuffer_width * framebuffer_height * 4);
            if (!result)
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA,
                             GL_UNSIGNED_BYTE, original_pixels.data());
            nkui_renderer_stats moved_rows{}, restored_rows{};
            if (!result && (nkui_text_layout_edit(wrapped_rows, 0, 0, "\n") != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &moved_rows) != NKUI_OK))
                result = 52;
            // The inserted row is blank and has no glyph texture. Only the
            // enclosing custom-node raster misses; moved text rows must hit.
            if (!result && (moved_rows.raster_cache_hits < unicode_rows.raster_cache_hits + 2 ||
                moved_rows.raster_cache_misses != unicode_rows.raster_cache_misses + 1)) {
                std::fprintf(stderr, "Newline insertion discarded moved row rasters\n");
                result = 53;
            }
            if (!result) {
                std::vector<uint8_t> moved_pixels(original_pixels.size());
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA,
                             GL_UNSIGNED_BYTE, moved_pixels.data());
                // The second original row moves down by the explicit line height.
                for (int y = 28; y < 52; ++y)
                    for (int x = 8; x < 148; ++x)
                        for (int channel = 0; channel < 4; ++channel) {
                            const auto old_pixel = ((framebuffer_height - y - 1) *
                                                    framebuffer_width + x) * 4 + channel;
                            const auto new_pixel = ((framebuffer_height - y - 25) *
                                                    framebuffer_width + x) * 4 + channel;
                            if (original_pixels[old_pixel] != moved_pixels[new_pixel])
                                result = 57;
                        }
            }
            if (!result && (nkui_text_layout_edit(wrapped_rows, 0, 1, "") != NKUI_OK ||
                nkui_layout_session_render_frame(renderer, session, surface, &frame_info, 0) != NKUI_OK ||
                nkui_renderer_get_stats(renderer, &restored_rows) != NKUI_OK))
                result = 54;
            if (!result && (restored_rows.raster_cache_hits < moved_rows.raster_cache_hits + 2 ||
                restored_rows.raster_cache_misses != moved_rows.raster_cache_misses + 2))
                result = 55;
            if (!result) {
                std::vector<uint8_t> restored_pixels(original_pixels.size());
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA,
                             GL_UNSIGNED_BYTE, restored_pixels.data());
                if (restored_pixels != original_pixels)
                    result = 56;
            }
            if (!result)
                std::printf("moved row raster cache: inserted hits=%llu misses=%llu; deleted hits=%llu misses=%llu\n",
                    static_cast<unsigned long long>(moved_rows.raster_cache_hits - unicode_rows.raster_cache_hits),
                    static_cast<unsigned long long>(moved_rows.raster_cache_misses - unicode_rows.raster_cache_misses),
                    static_cast<unsigned long long>(restored_rows.raster_cache_hits - moved_rows.raster_cache_hits),
                    static_cast<unsigned long long>(restored_rows.raster_cache_misses - moved_rows.raster_cache_misses));


        }
        // Cached row origins use layout coordinates even when raster density changes.
        // Read back separated glyph rows to catch double zoom and disappearing rows.
        if (!result && (nkui_text_layout_set_text(wrapped_rows, "Hg\nHg\nHg\nHg") != NKUI_OK ||
            nkui_text_layout_set_color(wrapped_rows, {0.0f, 0.0f, 0.85f, 1.0f}) != NKUI_OK))
            result = 57;
        for (float zoom : {1.5f, 2.0f}) {
            for (float scroll : {0.0f, 24.0f}) {
                if (result) break;
                std::vector<uint8_t> zoom_commands;
                append_bytes(zoom_commands, nkui_transform_command{
                    {NKUI_COMMAND_SET_TRANSFORM, NKUI_COMMAND_VERSION, sizeof(nkui_transform_command)},
                    {1.0f, 0.0f, 0.0f, 1.0f, 8.0f, 4.0f - scroll}});
                append_bytes(zoom_commands, nkui_draw_rect_command{
                    {NKUI_COMMAND_DRAW_TEXT_LAYOUT, NKUI_COMMAND_VERSION, sizeof(nkui_draw_rect_command)},
                    wrapped_rows, 0.0f, 0.0f, 0.0f, 0.0f});
                const nkui_frame_info zoom_info{sizeof(zoom_info), framebuffer_width / zoom,
                    framebuffer_height / zoom, framebuffer_width, framebuffer_height, zoom};
                if (nkui_display_list_submit(text_list, zoom_commands.data(),
                    static_cast<uint32_t>(zoom_commands.size())) != NKUI_OK ||
                    nkui_layout_session_render_frame(renderer, session, surface, &zoom_info, 0) != NKUI_OK) {
                    result = 58;
                    break;
                }
                std::vector<uint8_t> pixels(framebuffer_width * framebuffer_height * 4);
                glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
                std::vector<int> starts;
                int band_start = -1;
                // transaction() places the custom node at y=20 with height=64.
                // Compare complete glyph bands from the top: clipped bands
                // have truncated bounds and cannot establish row spacing.
                const int clip_top = static_cast<int>(std::ceil(20.0f * zoom));
                const int clip_bottom = static_cast<int>(std::floor(84.0f * zoom));
                for (int y = 0; y <= framebuffer_height; ++y) {
                    bool ink = false;
                    for (int x = 0; y < framebuffer_height && x < framebuffer_width; ++x) {
                        const auto *rgba = &pixels[((framebuffer_height - y - 1) * framebuffer_width + x) * 4];
                        ink = ink || (rgba[2] > 150 && rgba[0] < 80 && rgba[1] < 80);
                    }
                    if (ink && band_start < 0) band_start = y;
                    if (!ink && band_start >= 0) {
                        if (band_start > clip_top && y < clip_bottom) starts.push_back(band_start);
                        band_start = -1;
                    }
                }
                if (starts.size() < 2 || starts.size() > 4) result = 59;
                for (size_t row = 1; row < starts.size(); ++row)
                    if (std::abs((starts[row] - starts[row - 1]) - 24.0f * zoom) > 1.0f) result = 60;
                if (result) std::fprintf(stderr, "zoom row regression: zoom=%.1f scroll=%.1f rows=%zu code=%d\n",
                    zoom, scroll, starts.size(), result);
            }
        }
        if (wrapped_rows.id)
            nkui_resource_destroy(wrapped_rows);
        nkui_layout_session_clear_custom_paints(session);
        nkui_display_list_destroy(text_list);
        nkui_resource_destroy(text_layout);
        nkui_display_list_destroy(custom_list);
        nkui_resource_destroy(custom_path);
        nkui_resource_destroy(custom_paint);
    }

    if (!result) {
        // Keep one retained border open while the host changes its render scale.
        // Isolating it exercises the same content/composite path as tooltips.
        nkui_display_list border_list{}, composite_list{};
        nkui_display_list_create(&border_list);
        nkui_display_list_create(&composite_list);
        std::vector<uint8_t> border_commands, composite_commands;
        append_bytes(border_commands, nkui_draw_rect_border_command{
            {NKUI_COMMAND_DRAW_RECT_BORDER, NKUI_COMMAND_VERSION,
             sizeof(nkui_draw_rect_border_command)},
            0, 0, 50.4f, 32.6f, 0, {1, 1, 1, 1}});
        nkui_layer_command layer{};
        layer.header = {NKUI_COMMAND_BEGIN_LAYER, NKUI_LAYER_COMMAND_VERSION, sizeof(layer) + sizeof(nkui_effect_op_command)};
        layer.opacity = 0.99f;
        layer.composite_mode = NKUI_COMPOSITE_SOURCE_OVER;
        layer.width = 50.4f;
        layer.height = 32.6f;
        layer.flags = NKUI_LAYER_ISOLATED | NKUI_LAYER_HAS_BOUNDS;
        layer.foreground_count = 1;
        nkui_effect_op_command shadow{};
        shadow.kind = NKUI_EFFECT_DROP_SHADOW;
        shadow.color_matrix[0] = 3;
        shadow.color_matrix[3] = 2;
        shadow.color_matrix[7] = 0.25f;
        append_bytes(composite_commands, layer);
        append_bytes(composite_commands, shadow);
        append_bytes(composite_commands, nkui_command_header{
            NKUI_COMMAND_END_LAYER, NKUI_COMMAND_VERSION, sizeof(nkui_command_header)});
        if (nkui_display_list_submit(border_list, border_commands.data(), border_commands.size()) != NKUI_OK ||
            nkui_display_list_submit(composite_list, composite_commands.data(), composite_commands.size()) != NKUI_OK)
            result = 90;
        for (float zoom : {1.0f, 1.1f, 1.2f, 1.25f, 1.4f, 1.5f, 1.75f, 2.0f, 2.25f, 0.9f, 1.0f}) {
            if (result) break;
            auto tree = transaction(framebuffer_width / zoom, framebuffer_height / zoom);
            const size_t node = NKUI_LAYOUT_TRANSACTION_HEADER_BYTES + NKUI_LAYOUT_NODE_RECORD_BYTES;
            write_u32(tree, node + NKUI_LAYOUT_NODE_VISUAL_KIND_OFFSET, NKUI_LAYOUT_VISUAL_CUSTOM);
            write_float(tree, node + NKUI_LAYOUT_NODE_WIDTH_VALUE_OFFSET, 50.4f);
            write_float(tree, node + NKUI_LAYOUT_NODE_HEIGHT_VALUE_OFFSET, 32.6f);
            write_float(tree, node + NKUI_LAYOUT_NODE_TRANSFORM_TX_OFFSET, 8.2f);
            write_float(tree, node + NKUI_LAYOUT_NODE_TRANSFORM_TY_OFFSET, 8.3f);
            write_u32(tree, node + NKUI_LAYOUT_NODE_RECORD_BYTES + NKUI_LAYOUT_NODE_FLAGS_OFFSET, 0);
            const nkui_layout_frame_input input{sizeof(input), framebuffer_width / zoom,
                                                framebuffer_height / zoom, 0};
            const nkui_frame_info info{sizeof(info), framebuffer_width / zoom, framebuffer_height / zoom,
                                       framebuffer_width, framebuffer_height, zoom};
            const auto submitted = nkui_layout_session_submit(session, tree.data(), tree.size(), &input);
            const auto painted = nkui_layout_session_set_custom_paint(session, 2, border_list);
            const auto composited = nkui_layout_session_set_custom_paint_composite(session, 2, composite_list);
            const auto rendered = nkui_layout_session_render_frame(renderer, session, surface, &info, 0);
            if (submitted != NKUI_OK || painted != NKUI_OK || composited != NKUI_OK || rendered != NKUI_OK) {
                std::fprintf(stderr, "border zoom frame failed: %.2f submit=%d paint=%d composite=%d render=%d\n",
                             zoom, submitted, painted, composited, rendered);
                result = 90;
                break;
            }
            std::vector<uint8_t> pixels(framebuffer_width * framebuffer_height * 4);
            glReadPixels(0, 0, framebuffer_width, framebuffer_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
            const auto ink = [&](int x, int y) {
                return pixels[((framebuffer_height - 1 - y) * framebuffer_width + x) * 4] > 200;
            };
            const int cx = static_cast<int>((8.2f + 25.2f) * zoom);
            const int cy = static_cast<int>((8.3f + 16.3f) * zoom);
            int left = 0, right = 0, top = 0, bottom = 0;
            for (int x = 0; x < framebuffer_width; ++x)
                if (ink(x, cy)) (x < cx ? left : right)++;
            for (int y = 0; y < framebuffer_height; ++y)
                if (ink(cx, y)) (y < cy ? top : bottom)++;
            if (left != 1 || right != 1 || top != 1 || bottom != 1) {
                std::fprintf(stderr, "retained border sides differ at zoom %.2f: %d %d %d %d\n",
                             zoom, left, right, top, bottom);
                result = 91;
            }
        }
        nkui_layout_session_clear_custom_paints(session);
        nkui_layout_session_clear_custom_paint_composite(session, 2);
        nkui_display_list_destroy(composite_list);
        nkui_display_list_destroy(border_list);
    }

    if (nkui_layout_session_destroy(session) != NKUI_OK ||
        nkui_layout_session_destroy(session) != NKUI_ERROR_INVALID_HANDLE)
        result = 17;
    nkui_display_list_destroy(list);
    nkui_renderer_destroy(renderer);
    nkui_resource_destroy(fonts);
    nk_surface_destroy(surface);
    nk_window_destroy(window);
    nk_shutdown();
    if (!result)
        std::printf("PASS: layout-session render path renders primitives, scales, and custom "
                    "paints\n");
    return result;
}
