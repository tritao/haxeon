#ifndef NATIVEKIT_UI_TEXT_RASTER_H
#define NATIVEKIT_UI_TEXT_RASTER_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace nkui {

// All preparation and publication paths use the same scale for both geometry
// and cache identity. Zero denotes an invalid or unrepresentable scale.
struct TextRasterScale {
    int32_t key = 0;
    float value = 0.0f;
};

constexpr float kTextRasterPrecision = 1024.0f;
constexpr float kAlphaGlyphSizeStep = 1.0f / kTextRasterPrecision;
// Allows scale/font-size quantization error, measured in device pixels.
constexpr float kGlyphTexelTolerance = 0.01f;

inline TextRasterScale text_raster_scale(float requested) {
    if (!std::isfinite(requested) || requested <= 0.0f)
        return {};
    const double rounded = std::max(1.0, std::round(
        static_cast<double>(requested) * kTextRasterPrecision));
    if (rounded > std::numeric_limits<int32_t>::max())
        return {};
    const auto key = static_cast<int32_t>(rounded);
    return {key, static_cast<float>(key) / kTextRasterPrecision};
}

// Rasterize at the largest stretch of the device transform. This retains
// resolution under rotation, reflection, nonuniform scale and shear; geometry
// still receives the original transform and filtering handles the other axis.
inline TextRasterScale text_raster_scale_for_transform(const float transform[6]) {
    for (int i = 0; i < 6; ++i)
        if (!std::isfinite(transform[i]))
            return {};
    const double a = transform[0], b = transform[1];
    const double c = transform[2], d = transform[3];
    const double first_length_squared = a * a + b * b;
    const double second_length_squared = c * c + d * d;
    const double dot = a * c + b * d;
    // Largest eigenvalue of transpose(M) * M, whose square root is the
    // maximum singular value (the maximum stretch of any unit direction).
    const double largest = 0.5 * (first_length_squared + second_length_squared +
        std::hypot(first_length_squared - second_length_squared, 2.0 * dot));
    const float scale = static_cast<float>(std::sqrt(largest));
    // A collapsed transform has nothing to paint, but need not reject a frame.
    return text_raster_scale(scale == 0.0f ? 1.0f : scale);
}

} // namespace nkui

#endif
