#include "cxx_thunk_fixture.hpp"

namespace cxxthunk {
    int Counter::value() const {
        return 42;
    }

    void Counter::fail() {
        throw std::runtime_error("counter failed");
    }

    Counter *acquire() noexcept {
        static Counter counter;
        return &counter;
    }

    int apply(BinaryCallback callback, int left, int right) noexcept {
        return callback == nullptr ? 0 : callback(left, right);
    }

    int add(int left, int right) {
        if (right == 0)
            throw std::runtime_error("division-like failure");
        return left + right;
    }
}
