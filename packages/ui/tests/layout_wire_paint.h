#ifndef NATIVEKIT_UI_LAYOUT_WIRE_PAINT_H
#define NATIVEKIT_UI_LAYOUT_WIRE_PAINT_H

#include "nativekit_ui_layout.h"
#include <array>

/** Native test input owner for the borrowed paint-record span. */
class LayoutWirePaint {
  public:
    LayoutWirePaint() {
        for (auto &p : records_) {
            p.text_red = p.text_green = p.text_blue = p.text_alpha = 1;
            p.generation = 1;
            p.flags = 1;
        }
    }
    nkui_layout_paint_record &record(std::size_t index) { return records_[index]; }
    void background(std::size_t index, double red, double green, double blue, double alpha) {
        auto &p = records_[index];
        p.background_red = red; p.background_green = green; p.background_blue = blue; p.background_alpha = alpha;
        p.flags |= 2;
    }
    nkui_result submit(nkui_layout_session session, const uint8_t *transaction, uint32_t bytes,
                       const nkui_layout_frame_input *frame) {
        const auto result = nkui_layout_session_submit(session, transaction, bytes,
            reinterpret_cast<const uint8_t *>(records_.data()), sizeof(records_), frame);
        if (result == NKUI_OK) for (auto &p : records_) p.flags &= ~2;
        return result;
    }
    nkui_result verify(nkui_layout_session session, const uint8_t *transaction, uint32_t bytes) const {
        return nkui_layout_session_verify_tree(session, transaction, bytes,
            reinterpret_cast<const uint8_t *>(records_.data()), sizeof(records_));
    }
  private:
    std::array<nkui_layout_paint_record, 4096> records_{};
};

#endif
