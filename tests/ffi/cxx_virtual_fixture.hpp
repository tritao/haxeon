#pragma once

namespace cxxvirt {
    class Renderer {
    public:
        virtual int draw(int value) noexcept {
            return value + 1;
        }
    };

    class SoftwareRenderer : public Renderer {
    public:
        int draw(int value) noexcept override {
            return value * 2;
        }
    };

    Renderer *acquire() noexcept;
}
