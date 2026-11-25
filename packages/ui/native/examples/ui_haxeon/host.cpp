#include <emscripten/emscripten.h>

#include "core/runtime.hpp"
#include "nativekit_input.h"

#include <cstring>
#include <utility>

#include <string>

namespace {

std::string diagnostic_message;
std::string diagnostic_stack;
std::string diagnostic_breadcrumbs;

} // namespace

extern "C" {

EMSCRIPTEN_KEEPALIVE void nkui_browser_pointer_event(
    nk_handle window, uint32_t pointer_id, nk_touch_action action, nk_touch_tool tool,
    nk_modifiers modifiers, double x, double y, float pressure, float tilt_x, float tilt_y) {
    const nk_touch_event touch{pointer_id, action, tool, modifiers, x, y, pressure, tilt_x, tilt_y, 0};
    nk::core::QueuedEvent event;
    event.kind = NK_EVENT_TOUCH;
    event.source = window;
    event.data.resize(sizeof touch);
    std::memcpy(event.data.data(), &touch, sizeof touch);
    nk::core::push_event(std::move(event));
}

EM_JS(void, install_pointer_events,
      (nk_handle window, int enabled, int begin, int move, int end, int cancel, int finger, int stylus,
       int shift, int control, int alt, int meta), {
    const canvas = Module.canvas;
    if (!canvas) return;
    if (Module.removeUiPointerEvents) Module.removeUiPointerEvents();
    if (!enabled) return;

    const listeners = new AbortController();
    const touchAction = canvas.style.touchAction;
    canvas.style.touchAction = 'none';
    Module.removeUiPointerEvents = () => {
        listeners.abort();
        canvas.style.touchAction = touchAction;
        delete Module.removeUiPointerEvents;
    };
    const options = { capture: true, passive: false, signal: listeners.signal };
    // NativeKit still owns mouse input. Suppress the compatibility mouse sequence
    // and the legacy touch stream when Pointer Events provide the same contact.
    for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) {
        canvas.ownerDocument.addEventListener(type, event => {
            if (event.target !== canvas) return;
            event.preventDefault();
            event.stopImmediatePropagation();
        }, options);
    }
    for (const [type, action] of [['pointerdown', begin], ['pointermove', move],
                                 ['pointerup', end], ['pointercancel', cancel]]) {
        canvas.addEventListener(type, event => {
            if (event.pointerType !== 'touch' && event.pointerType !== 'pen') return;
            if (action === begin) {
                event.preventDefault();
                canvas.focus({ preventScroll: true });
                canvas.setPointerCapture(event.pointerId);
            }
            const rect = canvas.getBoundingClientRect();
            const modifiers = (event.shiftKey ? shift : 0) | (event.ctrlKey ? control : 0)
                | (event.altKey ? alt : 0) | (event.metaKey ? meta : 0);
            _nkui_browser_pointer_event(window, event.pointerId, action,
                event.pointerType === 'pen' ? stylus : finger, modifiers,
                event.clientX - rect.left, event.clientY - rect.top,
                event.pressure, event.tiltX, event.tiltY);
        }, options);
    }
});

void nkui_browser_pointer_events(nk_handle window, uint32_t enabled) {
    install_pointer_events(window, enabled, NK_TOUCH_BEGIN, NK_TOUCH_MOVE, NK_TOUCH_END, NK_TOUCH_CANCEL,
                           NK_TOUCH_TOOL_FINGER, NK_TOUCH_TOOL_STYLUS, NK_MOD_SHIFT, NK_MOD_CONTROL,
                           NK_MOD_ALT, NK_MOD_SUPER);
}

void nkui_showcase_diagnostic_report(int, const char *message, const char *stack,
                                     const char *breadcrumbs) {
    diagnostic_message = message ? message : "";
    if (const auto native_diagnostic = nk_last_error(); native_diagnostic && *native_diagnostic) {
        diagnostic_message += " [NativeKit: ";
        diagnostic_message += native_diagnostic;
        diagnostic_message += ']';
    }
    diagnostic_stack = stack ? stack : "";
    diagnostic_breadcrumbs = breadcrumbs ? breadcrumbs : "";
}

const char *nkui_showcase_diagnostic_message() {
    return diagnostic_message.c_str();
}

const char *nkui_showcase_diagnostic_stack() {
    return diagnostic_stack.c_str();
}

const char *nkui_showcase_diagnostic_breadcrumbs() {
    return diagnostic_breadcrumbs.c_str();
}

} // extern "C"

// The Haxeon guest owns the application loop.  This executable only supplies
// the browser runtime and the NativeKit/UI C ABI exports that the guest imports.
int main() {
    return 0;
}
