#pragma once

#include "nativekit.h"
#include "nativekit_graphics.h"
#include "nativekit_window.h"
#include "nativekit_time.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <type_traits>

// Readbacks must finish before GTK presents and retires the callback's framebuffer.
template <class Run>
int with_surface_frame(nk_window window, nk_surface surface, int logical_width, int logical_height, Run &&run) {
    float scale = 0;
    if (nk_window_get_scale(window, &scale) != NK_OK || scale <= 0) return 100;
    struct Invocation {
        std::remove_reference_t<Run> *run;
        int width, height;
        int result = 101;
        bool running = false;
        bool complete = false;
    } invocation{&run, static_cast<int>(std::lround(logical_width * scale)),
                 static_cast<int>(std::lround(logical_height * scale))};
    if (nk_surface_set_frame_mode(surface, NK_SURFACE_FRAME_ON_DEMAND) != NK_OK ||
        nk_surface_set_frame_callback(surface,
            [](nk_surface surface, int32_t width, int32_t height, void *data) {
                auto &invocation = *static_cast<Invocation *>(data);
                if (invocation.running || invocation.complete) return;
                if (width != invocation.width || height != invocation.height) {
                    nk_surface_request_frame(surface);
                    return;
                }
                invocation.running = true;
                invocation.result = (*invocation.run)(width, height);
                invocation.complete = true;
            }, &invocation) != NK_OK ||
        nk_window_activate(window) != NK_OK || nk_surface_request_frame(surface) != NK_OK)
        return 102;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (!invocation.complete && std::chrono::steady_clock::now() < deadline) {
        nk_event event{};
        event.struct_size = sizeof(event);
        const auto result = nk_poll_event(&event);
        nk_event_release(&event);
        if (result != NK_OK) break;
        if (!invocation.complete) nk_wait_events_timeout(.001);
    }
    nk_surface_set_frame_callback(surface, nullptr, nullptr);
    if (!invocation.complete) std::fprintf(stderr, "test surface did not deliver a full-sized frame\n");
    return invocation.result;
}
