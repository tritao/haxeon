#ifndef NATIVEKIT_UI_LAYOUT_ID_INDEX_H
#define NATIVEKIT_UI_LAYOUT_ID_INDEX_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace nkui {

/** Reusable ID-to-vector index. Zero is reserved; duplicate IDs retain their first occurrence. */
class LayoutIdIndex {
  public:
    static constexpr std::size_t missing = std::numeric_limits<std::size_t>::max();

    void reset(std::size_t count) {
        active_ = 0;
        if (!count) return;
        std::size_t capacity = 8;
        while (capacity / 2 < count) capacity *= 2;
        if (entries_.size() < capacity) entries_.resize(capacity);
        std::fill_n(entries_.begin(), capacity, Entry{});
        active_ = capacity;
    }

    void insert(uint64_t id, std::size_t index) {
        if (!id || !active_) return;
        auto slot = bucket(id);
        while (entries_[slot].id && entries_[slot].id != id) slot = (slot + 1) & (active_ - 1);
        if (!entries_[slot].id) entries_[slot] = {id, index};
    }

    std::size_t find(uint64_t id) const {
        if (!id || !active_) return missing;
        auto slot = bucket(id);
        while (entries_[slot].id) {
            if (entries_[slot].id == id) return entries_[slot].index;
            slot = (slot + 1) & (active_ - 1);
        }
        return missing;
    }

  private:
    struct Entry { uint64_t id = 0; std::size_t index = 0; };
    std::vector<Entry> entries_;
    std::size_t active_ = 0;

    std::size_t bucket(uint64_t id) const {
        id ^= id >> 33;
        id *= UINT64_C(0xff51afd7ed558ccd);
        id ^= id >> 33;
        return static_cast<std::size_t>(id) & (active_ - 1);
    }
};

} // namespace nkui
#endif
