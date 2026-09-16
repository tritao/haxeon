#pragma once

#include <cstddef>
#include <vector>

namespace nkui {
    class HostedDisplayList {
    public:
        std::size_t size() const noexcept;

    private:
        std::vector<unsigned char> storage;
    };
}
