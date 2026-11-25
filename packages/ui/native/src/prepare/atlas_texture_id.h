#ifndef NATIVEKIT_UI_ATLAS_TEXTURE_ID_H
#define NATIVEKIT_UI_ATLAS_TEXTURE_ID_H

#include <atomic>
#include <cstdint>
#include <cstddef>
#include <functional>
#include <limits>

namespace nkui {

/** Atlas identities are opaque and never reused during a process lifetime. */
struct AtlasTextureId {
    uint64_t value = 0;
};

/** Saturate on exhaustion rather than wrapping into an existing renderer key. */
class AtlasTextureIdSequence {
public:
    explicit AtlasTextureIdSequence(uint64_t last = 0) : last_(last) {}

    AtlasTextureId allocate() {
        auto last = last_.load(std::memory_order_relaxed);
        while (last != std::numeric_limits<uint64_t>::max()) {
            if (last_.compare_exchange_weak(last, last + 1, std::memory_order_relaxed))
                return {last + 1};
        }
        return {};
    }

private:
    std::atomic<uint64_t> last_;
};

/** The content generation changes when an atlas page is rebuilt. */
struct AtlasTextureKey {
    AtlasTextureId texture;
    uint32_t generation = 0;

    bool operator==(const AtlasTextureKey &other) const {
        return texture.value == other.texture.value && generation == other.generation;
    }
};

struct AtlasTextureKeyHash {
    size_t operator()(const AtlasTextureKey &key) const {
        const auto hash = std::hash<uint64_t>{}(key.texture.value);
        return hash ^ (std::hash<uint32_t>{}(key.generation) + size_t{0x9e3779b9} +
                       (hash << 6) + (hash >> 2));
    }
};

} // namespace nkui

#endif
