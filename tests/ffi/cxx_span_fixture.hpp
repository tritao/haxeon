#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace cxxspan {
    class Buffer {
    public:
        int byteCount(std::span<const std::byte> value) const noexcept;
        int sum(std::span<const uint8_t> value) const noexcept;
    };

    Buffer *acquire() noexcept;
    int byteCount(std::span<const std::byte> value) noexcept;
    int sum(std::span<const uint8_t> value) noexcept;
}
