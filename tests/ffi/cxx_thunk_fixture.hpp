#pragma once

#if defined(__clang__)
#define HXI_RETAINED __attribute__((annotate("hxi:retained")))
#else
#define HXI_RETAINED
#endif

namespace cxxthunk {
    using BinaryCallback = int (*)(int, int) noexcept;

    class Counter {
    public:
        int value() const;
        void fail();
    };

    Counter *acquire() noexcept;
    BinaryCallback acquire_handler() noexcept;
    int apply(BinaryCallback callback, int left, int right) noexcept;
    void set_handler(BinaryCallback callback HXI_RETAINED) noexcept;
    void clear_handler() noexcept;
    int fire_handler(int value) noexcept;
    int add(int left, int right);
}
