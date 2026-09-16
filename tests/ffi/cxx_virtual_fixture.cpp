#include "cxx_virtual_fixture.hpp"

namespace cxxvirt {
    Renderer *acquire() noexcept {
        static SoftwareRenderer renderer;
        return &renderer;
    }
}
