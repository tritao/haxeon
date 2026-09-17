#pragma once

#include <stdexcept>

namespace cxxthunk {
    class Counter {
    public:
        int value() const;
        void fail();
    };

    Counter *acquire() noexcept;
    int add(int left, int right);
}
