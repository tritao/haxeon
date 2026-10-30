#pragma once

#include <chrono>
#include <cstdlib>

namespace nkui {

// Read once; disabled submissions do not read the clock or format diagnostics.
inline bool layout_cost_enabled() {
    static const bool enabled = [] {
        const char *value = std::getenv("HAXEON_UI_LAYOUT_COST");
        return value && value[0] == '1' && value[1] == '\0';
    }();
    return enabled;
}

inline double layout_cost_time() {
    return layout_cost_enabled()
        ? std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count()
        : 0.0;
}

} // namespace nkui
