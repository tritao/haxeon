#include "cxx_string_view_fixture.hpp"

namespace cxxview {
    int Text::count(std::string_view value) const noexcept {
        return static_cast<int>(value.size());
    }

    Text *acquire() noexcept {
        static Text text;
        return &text;
    }

    int count(std::string_view value) noexcept {
        return static_cast<int>(value.size());
    }
}
