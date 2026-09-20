#pragma once

#include <stdexcept>

namespace cxxthunk {
    using BinaryCallback = int (*)(int, int) noexcept;

    class Counter {
    public:
        int value() const;
        void fail();
    };

    Counter *acquire() noexcept;
    int apply(BinaryCallback callback, int left, int right) noexcept;
    int add(int left, int right);
}
