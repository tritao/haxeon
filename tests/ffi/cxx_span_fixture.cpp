#include "cxx_span_fixture.hpp"

namespace cxxspan {
    int Buffer::byteCount(std::span<const std::byte> value) const noexcept {
        return static_cast<int>(value.size());
    }

    int Buffer::sum(std::span<const uint8_t> value) const noexcept {
        int result = 0;
        for (auto item : value)
            result += item;
        return result;
    }

    Buffer *acquire() noexcept {
        static Buffer buffer;
        return &buffer;
    }

    int byteCount(std::span<const std::byte> value) noexcept {
        return static_cast<int>(value.size());
    }

    int sum(std::span<const uint8_t> value) noexcept {
        int result = 0;
        for (auto item : value)
            result += item;
        return result;
    }
}
