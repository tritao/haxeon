#include "cxx_runtime_fixture.hpp"

namespace nkui {
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

    void mark(DisplayList &value) noexcept {
        value.count = 1;
    }

    int score(const DisplayList &value) noexcept {
        return value.count + 41;
    }
}
