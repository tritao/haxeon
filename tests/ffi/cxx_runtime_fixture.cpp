#include "cxx_runtime_fixture.hpp"

namespace nkui {
    static BinaryCallback retained_handler = nullptr;

    void DisplayList::reset() noexcept {
        count = 0;
    }

    int DisplayList::size() const noexcept {
        return count;
    }

    int DisplayList::make(int value) noexcept {
        return value * 2;
    }

    DisplayList *acquire() noexcept {
        static DisplayList value{0};
        return &value;
    }

    int apply(BinaryCallback callback, int left, int right) noexcept {
        return callback == nullptr ? 0 : callback(left, right);
    }

    int apply_raw(int (*callback)(int), int value) noexcept {
        return callback == nullptr ? 0 : callback(value);
    }

    void set_handler(BinaryCallback callback) noexcept {
        retained_handler = callback;
    }

    void clear_handler() noexcept {
        retained_handler = nullptr;
    }

    int fire_handler(int value) noexcept {
        return retained_handler == nullptr ? 0 : retained_handler(value, value);
    }

    void mark(DisplayList &value) noexcept {
        value.count = 1;
    }

    int score(const DisplayList &value) noexcept {
        return value.count + 41;
    }
}
