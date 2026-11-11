#ifndef NATIVEKIT_UI_PAINT_RECORD_H
#define NATIVEKIT_UI_PAINT_RECORD_H

#include <stdint.h>

/** Native-memory paint slot shared with the Haxe paint store. */
typedef struct nkui_layout_paint_record {
    double background_red, background_green, background_blue, background_alpha;
    double radius_top_left, radius_top_right, radius_bottom_left, radius_bottom_right;
    double text_red, text_green, text_blue, text_alpha;
    int32_t generation;
    int32_t flags;
} nkui_layout_paint_record;

#endif
