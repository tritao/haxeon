#pragma once

namespace cxx_bad {
    class VirtualThing {
    public:
        virtual void draw() noexcept;
    };

    void may_throw(int value);
    void move_only(int &&value) noexcept;
}
