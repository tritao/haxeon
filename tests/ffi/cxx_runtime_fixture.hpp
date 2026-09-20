#pragma once

namespace nkui {
    using BinaryCallback = int (*)(int, int) noexcept;

    class DisplayList {
    public:
        int count;

        void reset() noexcept;
        int size() const noexcept;
        static int make(int value) noexcept;
    };

    DisplayList *acquire() noexcept;
    int apply(BinaryCallback callback, int left, int right) noexcept;
    int apply_raw(int (*callback)(int), int value) noexcept;
    void mark(DisplayList &value) noexcept;
    int score(const DisplayList &value) noexcept;
}
