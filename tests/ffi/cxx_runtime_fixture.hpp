#pragma once

namespace nkui {
    class DisplayList {
    public:
        int count;

        void reset() noexcept;
        int size() const noexcept;
        static int make(int value) noexcept;
    };

    DisplayList *acquire() noexcept;
    void mark(DisplayList &value) noexcept;
    int score(const DisplayList &value) noexcept;
}
