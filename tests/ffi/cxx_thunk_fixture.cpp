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

    int add(int left, int right) {
        if (right == 0)
            throw std::runtime_error("division-like failure");
        return left + right;
    }
}
