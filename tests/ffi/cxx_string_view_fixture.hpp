#pragma once

#include <string_view>

namespace cxxview {
    class Text {
    public:
        int count(std::string_view value) const noexcept;
    };

    Text *acquire() noexcept;
    int count(std::string_view value) noexcept;
}
