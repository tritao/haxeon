// Single-header dependency implementations, compiled once for the library.
#include <charconv>
#include <cstring>

namespace {

// cgltf parses JSON numbers with atof by default, which honours LC_NUMERIC:
// under a comma-decimal locale "0.25" parses as 0. JSON numbers always use a
// period, so parse them locale-independently.
double parseJsonNumber(const char *text) {
    double value = 0.0;
    std::from_chars(text, text + std::strlen(text), value);
    return value;
}

} // namespace

#define CGLTF_ATOF(str) parseJsonNumber(str)
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"
