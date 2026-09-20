#pragma once

#if defined(__clang__)
#define HXI_RETAINED __attribute__((annotate("hxi:retained")))
#else
#define HXI_RETAINED
#endif

namespace cxx_bad {
    class VirtualThing {
    public:
        virtual void draw() noexcept;
    };

    void may_throw(int value);
    void move_only(int &&value) noexcept;
    void invalid_retained(int value HXI_RETAINED) noexcept;
}
