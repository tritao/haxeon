#ifndef NATIVEKIT_UI_TESTS_SCENE_RECORD_H
#define NATIVEKIT_UI_TESTS_SCENE_RECORD_H

#include "nativekit_ui_layout.h"

#include <cmath>
#include <cstdint>
#include <cstring>

/*
 * The framework lays its trees out and sends each node's geometry in its record (ADR 0009); the native tests place their
 * fixture nodes themselves with this.
 */
namespace fixture {

/**
 * Writes a node's geometry into the record at `record`: its bounds in layout coordinates, its text's width (its text starts
 * at its top-left corner), and its baseline in layout coordinates, NaN for none.
 */
inline void place(uint8_t *record, float x, float y, float width, float height, float text_width = 0.0f,
                  float baseline = std::nanf("")) {
    const float values[] = {x, y, width, height, 0.0f, 0.0f, text_width, baseline, 0.0f, 0.0f};
    std::memcpy(record + NKUI_LAYOUT_NODE_X_OFFSET, values, sizeof(values));
}

} // namespace fixture

#endif
