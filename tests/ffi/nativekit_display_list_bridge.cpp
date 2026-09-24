#include "nativekit_display_list_bridge.hpp"

namespace nkui {
    DisplayList *haxeon_display_list_acquire() {
        static DisplayList list;
        return &list;
    }
}
