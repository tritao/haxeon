#pragma once

namespace nkui {
    using Count = unsigned long;

    enum class Mode : unsigned int {
        Hidden = 0,
        Visible = 1
    };

    class DisplayList {
    public:
        void reset() noexcept;
        Count size() const noexcept;
        static int make(int value) noexcept;
    };

    DisplayList *acquire() noexcept;
    void consume(DisplayList &value, const Mode &mode) noexcept;
}
