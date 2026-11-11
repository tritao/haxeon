#ifndef NATIVEKIT_UI_LAYOUT_TEST_PAINT_H
#define NATIVEKIT_UI_LAYOUT_TEST_PAINT_H

#include "layout/layout_types.h"
#include <vector>

/** Native test owner for the same shared records used by a layout session. */
class LayoutTestPaint {
  public:
    void clear() { records_.clear(); source_.records = records_.data(); source_.count = 0; }
    void bind(nkui::LayoutNode &node) {
        node.paint_index = static_cast<uint32_t>(records_.size());
        node.paint_generation = 1;
        node.paint_source = &source_;
        nkui_layout_paint_record record{};
        record.text_red = record.text_green = record.text_blue = record.text_alpha = 1;
        record.generation = 1;
        record.flags = 1;
        records_.push_back(record);
        source_.records = records_.data();
        source_.count = records_.size();
    }
    nkui_layout_paint_record &record(const nkui::LayoutNode &node) { return records_[node.paint_index]; }
    void background(const nkui::LayoutNode &node, nkui::LayoutColor color) {
        auto &p = record(node);
        p.background_red = color.red; p.background_green = color.green;
        p.background_blue = color.blue; p.background_alpha = color.alpha;
    }
    void text(const nkui::LayoutNode &node, nkui::LayoutColor color) {
        auto &p = record(node);
        p.text_red = color.red; p.text_green = color.green; p.text_blue = color.blue; p.text_alpha = color.alpha;
    }
  private:
    std::vector<nkui_layout_paint_record> records_;
    nkui::LayoutPaintSource source_;
};

#endif
