#pragma once

#include "layout/layout_engine.h"

// Compile the same snapshot emitter with only the two former linear lookups restored.
// Keep its declaration mechanically identical to the production engine's declaration.
#undef NATIVEKIT_UI_LAYOUT_ENGINE_H
#define LayoutEngine LinearLayoutEngine
#include "layout/layout_engine.h"
#undef LayoutEngine
