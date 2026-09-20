#include "cxx_thunk_fixture.hpp"

namespace cxxthunk {
    static BinaryCallback retained_handler = nullptr;

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

    void set_handler(BinaryCallback callback) noexcept {
        retained_handler = callback;
    }

    void clear_handler() noexcept {
        retained_handler = nullptr;
    }

    int fire_handler(int value) noexcept {
        return retained_handler == nullptr ? 0 : retained_handler(value, value);
    }

    int add(int left, int right) {
        if (right == 0)
            throw std::runtime_error("division-like failure");
        return left + right;
    }
}
