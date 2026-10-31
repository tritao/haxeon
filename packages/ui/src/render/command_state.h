#pragma once

#include "nativekit_gpu.h"
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace nkui {

/** Removes redundant state records within one owned pass; draws remain in their original order. */
inline bool compact_gpu_commands(const std::vector<uint8_t> &input, std::vector<uint8_t> &output) {
    constexpr auto missing = std::numeric_limits<std::size_t>::max();
    std::array<std::size_t, 35> previous;
    previous.fill(missing);
    output.clear();
    const auto read = [&](std::size_t offset) {
        return uint32_t(input[offset]) | uint32_t(input[offset + 1]) << 8 |
            uint32_t(input[offset + 2]) << 16 | uint32_t(input[offset + 3]) << 24;
    };
    for (std::size_t offset = 0; offset < input.size();) {
        if (input.size() - offset < 8) return false;
        const auto opcode = read(offset), size = read(offset + 4);
        if (size < 8 || size > input.size() - offset) return false;
        std::size_t slot = missing;
        switch (opcode) {
        case NKGPU_COMMAND_APPLY_PIPELINE: slot = 0; break;
        case NKGPU_COMMAND_APPLY_SCISSOR: slot = 1; break;
        case NKGPU_COMMAND_APPLY_INDEX_BUFFER: slot = 2; break;
        case NKGPU_COMMAND_APPLY_VERTEX_BUFFER:
        case NKGPU_COMMAND_APPLY_IMAGE:
        case NKGPU_COMMAND_APPLY_GRAPHICS_IMAGE:
        case NKGPU_COMMAND_APPLY_SAMPLER:
        case NKGPU_COMMAND_APPLY_UNIFORMS:
            if (size < 12) return false;
            if (read(offset + 8) < 8) {
                const auto base = opcode == NKGPU_COMMAND_APPLY_VERTEX_BUFFER ? 3 :
                    opcode == NKGPU_COMMAND_APPLY_SAMPLER ? 19 :
                    opcode == NKGPU_COMMAND_APPLY_UNIFORMS ? 27 : 11;
                slot = base + read(offset + 8);
            }
            break;
        case NKGPU_COMMAND_DRAW: break;
        default: previous.fill(missing); break;
        }
        if (slot != missing) {
            const auto old = previous[slot];
            if (old != missing && read(old + 4) == size &&
                !std::memcmp(input.data() + old, input.data() + offset, size)) {
                offset += size;
                continue;
            }
            if (opcode == NKGPU_COMMAND_APPLY_PIPELINE) {
                // A changed shader invalidates uniform state; a non-indexed pipeline also drops its index binding.
                for (std::size_t uniform = 27; uniform < previous.size(); ++uniform) previous[uniform] = missing;
                previous[2] = missing;
            }
            previous[slot] = offset;
        }
        output.insert(output.end(), input.begin() + offset, input.begin() + offset + size);
        offset += size;
    }
    return true;
}

} // namespace nkui
