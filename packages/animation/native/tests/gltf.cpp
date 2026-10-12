#include "animkit.h"

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <clocale>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char *expression, int line) {
    if (!condition) {
        std::fprintf(stderr, "gltf.cpp:%d: check failed: %s\n", line, expression);
        ++failures;
    }
}

#define CHECK(expression) check((expression), #expression, __LINE__)

// ozz quantizes keyframes (quaternions to 16-bit components), so animated
// results agree to well under a millimetre rather than to float precision.
bool near(float a, float b) { return std::fabs(a - b) < 1e-3f; }

std::string base64(const std::vector<uint8_t> &bytes) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (size_t i = 0; i < bytes.size(); i += 3) {
        const uint32_t n = (bytes[i] << 16) | (i + 1 < bytes.size() ? bytes[i + 1] << 8 : 0)
            | (i + 2 < bytes.size() ? bytes[i + 2] : 0);
        out += table[(n >> 18) & 63];
        out += table[(n >> 12) & 63];
        out += i + 1 < bytes.size() ? table[(n >> 6) & 63] : '=';
        out += i + 2 < bytes.size() ? table[n & 63] : '=';
    }
    return out;
}

template <typename T> void append(std::vector<uint8_t> &buffer, std::initializer_list<T> values) {
    for (T value : values) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        buffer.insert(buffer.end(), bytes, bytes + sizeof(T));
    }
}

/*
 * Root "Armature" (node 0) has child "Bone" (node 1) one metre up glTF +Y.
 * "Skinned" (node 2) is one triangle whose third vertex follows Bone.
 * "Prop" (node 3) is a rigid triangle parented to Bone.
 * "Lift" moves Bone from y=1 to y=2 over one second; "Step" jumps it to y=3.
 */
std::string testDocument() {
    std::vector<uint8_t> buffer;
    append<float>(buffer, {0, 0, 0, 1, 0, 0, 0, 2, 0}); // 0: positions, 36 bytes
    append<uint16_t>(buffer, {0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0}); // 36: joints, 24 bytes
    append<float>(buffer, {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0}); // 60: weights, 48 bytes
    append<float>(buffer, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, // 108: inverse binds, 128 bytes
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1});
    append<float>(buffer, {0, 1}); // 236: lift times, 8 bytes
    append<float>(buffer, {0, 1, 0, 0, 2, 0}); // 244: lift translations, 24 bytes
    append<float>(buffer, {0, 0.5f}); // 268: step times, 8 bytes
    append<float>(buffer, {0, 1, 0, 0, 3, 0}); // 276: step translations, 24 bytes
    append<uint16_t>(buffer, {0, 1, 2, 0}); // 300: indices + pad, 8 bytes
    const size_t length = buffer.size();

    std::string json = R"({
  "asset": {"version": "2.0"},
  "scene": 0,
  "scenes": [{"nodes": [0]}],
  "nodes": [
    {"name": "Armature", "children": [1, 2]},
    {"name": "Bone", "translation": [0, 1, 0], "children": [3]},
    {"name": "Skinned", "mesh": 0, "skin": 0},
    {"name": "Prop", "mesh": 1, "translation": [0, 0, 1]}
  ],
  "skins": [{"joints": [0, 1], "inverseBindMatrices": 3}],
  "meshes": [
    {"name": "Body", "primitives": [{"attributes": {"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2},
      "indices": 8, "material": 0}]},
    {"name": "Hat", "primitives": [{"attributes": {"POSITION": 0}, "indices": 8}]}
  ],
  "materials": [{"name": "Paint", "doubleSided": true,
    "pbrMetallicRoughness": {"baseColorFactor": [1, 0.5, 0.25, 1], "metallicFactor": 0.0,
      "roughnessFactor": 0.75, "baseColorTexture": {"index": 0}}}],
  "textures": [{"source": 0}],
  "images": [{"uri": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="}],
  "animations": [
    {"name": "Lift", "samplers": [{"input": 4, "output": 5}],
      "channels": [{"sampler": 0, "target": {"node": 1, "path": "translation"}}]},
    {"name": "Step", "samplers": [{"input": 6, "output": 7, "interpolation": "STEP"}],
      "channels": [{"sampler": 0, "target": {"node": 1, "path": "translation"}}]}
  ],
  "accessors": [
    {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 2, 0]},
    {"bufferView": 1, "componentType": 5123, "count": 3, "type": "VEC4"},
    {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4"},
    {"bufferView": 3, "componentType": 5126, "count": 2, "type": "MAT4"},
    {"bufferView": 4, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]},
    {"bufferView": 5, "componentType": 5126, "count": 2, "type": "VEC3"},
    {"bufferView": 6, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [0.5]},
    {"bufferView": 7, "componentType": 5126, "count": 2, "type": "VEC3"},
    {"bufferView": 8, "componentType": 5123, "count": 3, "type": "SCALAR"}
  ],
  "bufferViews": [
    {"buffer": 0, "byteOffset": 0, "byteLength": 36},
    {"buffer": 0, "byteOffset": 36, "byteLength": 24},
    {"buffer": 0, "byteOffset": 60, "byteLength": 48},
    {"buffer": 0, "byteOffset": 108, "byteLength": 128},
    {"buffer": 0, "byteOffset": 236, "byteLength": 8},
    {"buffer": 0, "byteOffset": 244, "byteLength": 24},
    {"buffer": 0, "byteOffset": 268, "byteLength": 8},
    {"buffer": 0, "byteOffset": 276, "byteLength": 24},
    {"buffer": 0, "byteOffset": 300, "byteLength": 6}
  ],
  "buffers": [{"byteLength": )" + std::to_string(length)
        + R"(, "uri": "data:application/octet-stream;base64,)" + base64(buffer) + R"("}]
})";
    return json;
}

template <typename T> std::vector<T> read(ak_result (*fn)(ak_instance_handle, uint32_t, uint8_t *, uint32_t *),
    ak_instance_handle instance, uint32_t primitive) {
    uint32_t size = 0;
    CHECK(fn(instance, primitive, nullptr, &size) == AK_OK);
    std::vector<T> values(size / sizeof(T));
    CHECK(fn(instance, primitive, reinterpret_cast<uint8_t *>(values.data()), &size) == AK_OK);
    return values;
}

std::vector<float> positions(ak_instance_handle instance, uint32_t primitive) {
    return read<float>(ak_instance_read_positions, instance, primitive);
}

void checkPoint(const std::vector<float> &p, size_t vertex, float x, float y, float z, int line) {
    const bool ok = near(p[vertex * 3], x) && near(p[vertex * 3 + 1], y) && near(p[vertex * 3 + 2], z);
    if (!ok)
        std::fprintf(stderr, "gltf.cpp:%d: vertex %zu is (%g, %g, %g), expected (%g, %g, %g)\n", line, vertex,
            p[vertex * 3], p[vertex * 3 + 1], p[vertex * 3 + 2], x, y, z);
    check(ok, "vertex position", line);
}

#define CHECK_POINT(p, v, x, y, z) checkPoint(p, v, x, y, z, __LINE__)

} // namespace


/*
 * Two meshes of two triangles sharing an edge, each triangle with its own
 * flat normals as hard-edge exports author them. "Soft" folds by 30 degrees,
 * "Hard" by 90.
 */
std::string creaseDocument() {
    const float c = std::cos(0.5235988f), s = std::sin(0.5235988f);
    std::vector<uint8_t> buffer;
    append<float>(buffer, {0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, -c, -s}); // 0: soft positions
    append<float>(buffer, {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, -s, c, 0, -s, c, 0, -s, c}); // 72: soft normals
    append<float>(buffer, {0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, -1}); // 144: hard positions
    append<float>(buffer, {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, -1, 0, 0, -1, 0, 0, -1, 0}); // 216: hard normals
    append<uint16_t>(buffer, {0, 1, 2, 3, 4, 5}); // 288: indices, 12 bytes
    const size_t length = buffer.size();
    std::string json = R"({
  "asset": {"version": "2.0"},
  "scene": 0,
  "scenes": [{"nodes": [0, 1]}],
  "nodes": [{"name": "Soft", "mesh": 0}, {"name": "Hard", "mesh": 1}],
  "meshes": [
    {"name": "Soft", "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1}, "indices": 4}]},
    {"name": "Hard", "primitives": [{"attributes": {"POSITION": 2, "NORMAL": 3}, "indices": 4}]}
  ],
  "accessors": [
    {"bufferView": 0, "componentType": 5126, "count": 6, "type": "VEC3", "min": [0, -1, -1], "max": [1, 1, 0]},
    {"bufferView": 1, "componentType": 5126, "count": 6, "type": "VEC3"},
    {"bufferView": 2, "componentType": 5126, "count": 6, "type": "VEC3", "min": [0, 0, -1], "max": [1, 1, 0]},
    {"bufferView": 3, "componentType": 5126, "count": 6, "type": "VEC3"},
    {"bufferView": 4, "componentType": 5123, "count": 6, "type": "SCALAR"}
  ],
  "bufferViews": [
    {"buffer": 0, "byteOffset": 0, "byteLength": 72},
    {"buffer": 0, "byteOffset": 72, "byteLength": 72},
    {"buffer": 0, "byteOffset": 144, "byteLength": 72},
    {"buffer": 0, "byteOffset": 216, "byteLength": 72},
    {"buffer": 0, "byteOffset": 288, "byteLength": 12}
  ],
  "buffers": [{"byteLength": )" + std::to_string(length)
        + R"(, "uri": "data:application/octet-stream;base64,)" + base64(buffer) + R"("}]
})";
    return json;
}

void checkCreaseSmoothing() {
    const std::string document = creaseDocument();
    ak_asset_handle asset{};
    if (ak_asset_load_memory(reinterpret_cast<const uint8_t *>(document.data()),
            static_cast<uint32_t>(document.size()), &asset) != AK_OK) {
        std::fprintf(stderr, "crease load failed: %s\n", ak_last_error());
        ++failures;
        return;
    }
    ak_instance_handle instance{};
    CHECK(ak_instance_create(asset, &instance) == AK_OK);
    ak_asset_destroy(asset);
    CHECK(ak_instance_evaluate(instance) == AK_OK);

    // Soft: vertex 0 (shared with the neighbour) blends the two face normals,
    // so it tilts off the authored +Z (scene +X) by about half the fold.
    const std::vector<float> soft = read<float>(ak_instance_read_normals, instance, 0);
    const std::vector<float> hard = read<float>(ak_instance_read_normals, instance, 1);
    CHECK(soft.size() == 18 && hard.size() == 18);
    if (soft.size() == 18 && hard.size() == 18) {
        // Coincident vertices 0 and 3 agree after smoothing.
        for (int i = 0; i < 3; ++i) CHECK(near(soft[i], soft[9 + i]));
        // Scene +X is glTF +Z: the smoothed normal leans away from it, not onto it.
        CHECK(soft[0] < 0.999f && soft[0] > 0.9f);
        // A 90 degree edge stays hard: each vertex keeps its own face normal.
        CHECK(near(hard[0], 1.0f));
        CHECK(near(hard[9], 0.0f) && near(hard[9 + 2], -1.0f)); // glTF -Y is scene -Z
    }
    ak_instance_destroy(instance);
}

int main() {
    // JSON numbers must parse the same under a comma-decimal locale, as in a
    // desktop session with LC_NUMERIC=pt_PT.UTF-8.
    const char *const comma_locales[] = {"pt_PT.UTF-8", "pt_PT.utf8", "de_DE.UTF-8", "de_DE.utf8",
        "fr_FR.UTF-8", "fr_FR.utf8"};
    const char *locale = nullptr;
    for (const char *name : comma_locales)
        if ((locale = std::setlocale(LC_NUMERIC, name)) != nullptr) break;
    if (locale == nullptr) std::printf("animkit gltf: no comma-decimal locale; testing in C\n");

    const std::string document = testDocument();
    ak_asset_handle asset{};
    const ak_result loaded = ak_asset_load_memory(reinterpret_cast<const uint8_t *>(document.data()),
        static_cast<uint32_t>(document.size()), &asset);
    if (loaded != AK_OK) {
        std::fprintf(stderr, "load failed: %s\n", ak_last_error());
        return 1;
    }

    ak_asset_info info{};
    info.struct_size = sizeof(info);
    CHECK(ak_asset_get_info(asset, &info) == AK_OK);
    CHECK(info.joint_count == 4);
    CHECK(info.primitive_count == 2);
    CHECK(info.material_count == 1);
    CHECK(info.image_count == 1);
    CHECK(info.clip_count == 2);
    CHECK(info.warning_count == 0);
    for (uint32_t i = 0; i < info.warning_count; ++i) std::fprintf(stderr, "warning: %s\n", ak_asset_warning(asset, i));

    const int32_t bone = ak_asset_find_joint(asset, "Bone");
    const int32_t prop = ak_asset_find_joint(asset, "Prop");
    const int32_t armature = ak_asset_find_joint(asset, "Armature");
    CHECK(bone >= 0 && armature >= 0);
    CHECK(ak_asset_joint_parent(asset, static_cast<uint32_t>(bone)) == armature);
    CHECK(ak_asset_find_clip(asset, "Lift") == 0);
    CHECK(near(ak_asset_clip_duration(asset, 0), 1.0f));
    CHECK(std::strcmp(ak_asset_primitive_name(asset, 0), "Body") == 0);

    ak_primitive_info body{};
    body.struct_size = sizeof(body);
    CHECK(ak_asset_get_primitive(asset, 0, &body) == AK_OK);
    CHECK(body.vertex_count == 3 && body.index_count == 3 && body.skinned && body.material == 0);
    ak_primitive_info hat{};
    hat.struct_size = sizeof(hat);
    CHECK(ak_asset_get_primitive(asset, 1, &hat) == AK_OK);
    CHECK(!hat.skinned && hat.joint == ak_asset_find_joint(asset, "Prop"));

    ak_material_info material{};
    material.struct_size = sizeof(material);
    CHECK(ak_asset_get_material(asset, 0, &material) == AK_OK);
    CHECK(near(material.base_color[1], 0.5f) && near(material.roughness, 0.75f) && material.double_sided);
    CHECK(material.base_color_image == 0);
    ak_image_info image{};
    image.struct_size = sizeof(image);
    CHECK(ak_asset_get_image(asset, 0, &image) == AK_OK);
    CHECK(image.width == 1 && image.height == 1);

    ak_instance_handle instance{};
    CHECK(ak_instance_create(asset, &instance) == AK_OK);
    // GPU input contract: source bind streams plus the palette reproduce CPU skinning.
    auto readFloats = [&](auto read, uint32_t primitive) {
        uint32_t size = 0;
        CHECK(read(asset, primitive, nullptr, &size) == AK_OK);
        std::vector<float> values(size / sizeof(float));
        CHECK(read(asset, primitive, reinterpret_cast<uint8_t *>(values.data()), &size) == AK_OK);
        return values;
    };
    auto bind = readFloats(ak_asset_read_bind_positions, 0);
    auto weights = readFloats(ak_asset_read_joint_weights, 0);
    CHECK(bind.size() == 9 && weights.size() == 12);
    CHECK(near(weights[0], 1) && near(weights[3], 0));
    uint32_t indexBytes = 0;
    CHECK(ak_asset_read_joint_indices(asset, 0, nullptr, &indexBytes) == AK_OK);
    std::vector<uint16_t> paletteIndices(indexBytes / sizeof(uint16_t));
    CHECK(ak_asset_read_joint_indices(asset, 0, reinterpret_cast<uint8_t *>(paletteIndices.data()), &indexBytes) == AK_OK);
    CHECK(paletteIndices.size() == 12 && paletteIndices[8] == 1);
    uint32_t shortSize = 1;
    uint8_t shortBuffer = 0;
    CHECK(ak_asset_read_bind_positions(asset, 0, &shortBuffer, &shortSize) == AK_ERROR_BUFFER_TOO_SMALL);
    CHECK(shortSize == bind.size() * sizeof(float));
    CHECK(ak_asset_read_bind_positions(asset, 99, nullptr, &shortSize) == AK_ERROR_INVALID_ARGUMENT);
    CHECK(ak_asset_read_bind_positions(ak_asset_handle{}, 0, nullptr, &shortSize) == AK_ERROR_INVALID_HANDLE);
    CHECK(readFloats(ak_asset_read_joint_weights, 1).empty());
    auto rigidBind = readFloats(ak_asset_read_bind_positions, 1);
    auto bindNormals = readFloats(ak_asset_read_bind_normals, 0);
    auto rigidNormals = readFloats(ak_asset_read_bind_normals, 1);
    auto inverseBind = readFloats(ak_asset_read_inverse_bind_matrices, 0);
    CHECK(inverseBind.size() == 32 && near(inverseBind[16 + 13], -1));
    auto comparePalette = [&](uint32_t primitive, const std::vector<float> &source, const std::vector<float> &normals) {
        uint32_t size = 0;
        CHECK(ak_instance_read_skin_matrices(instance, primitive, nullptr, &size) == AK_OK);
        std::vector<float> palette(size / sizeof(float));
        CHECK(ak_instance_read_skin_matrices(instance, primitive, reinterpret_cast<uint8_t *>(palette.data()), &size) == AK_OK);
        CHECK(palette.size() == (primitive == 0 ? 32u : 16u));
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto cpu = positions(instance, primitive);
        uint32_t normalBytes = static_cast<uint32_t>(normals.size() * sizeof(float));
        std::vector<float> cpuNormals(normals.size());
        CHECK(ak_instance_read_normals(instance, primitive, reinterpret_cast<uint8_t *>(cpuNormals.data()), &normalBytes) == AK_OK);
        for (size_t vertex = 0; vertex < source.size() / 3; ++vertex) {
            float normal[3] = {};
            for (int axis = 0; axis < 3; ++axis) {
                float value = 0;
                for (int influence = 0; influence < (primitive == 0 ? 4 : 1); ++influence) {
                    const size_t at = vertex * 4 + influence;
                    const float weight = primitive == 0 ? weights[at] : 1.0f;
                    const size_t matrix = (primitive == 0 ? paletteIndices[at] : 0) * 16;
                    value += weight * (palette[matrix + axis] * source[vertex * 3]
                        + palette[matrix + 4 + axis] * source[vertex * 3 + 1]
                        + palette[matrix + 8 + axis] * source[vertex * 3 + 2] + palette[matrix + 12 + axis]);
                    normal[axis] += weight * (palette[matrix + axis] * normals[vertex * 3]
                        + palette[matrix + 4 + axis] * normals[vertex * 3 + 1]
                        + palette[matrix + 8 + axis] * normals[vertex * 3 + 2]);
                }
                CHECK(near(value, cpu[vertex * 3 + axis]));
            }
            const float length = std::sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
            for (int axis = 0; axis < 3; ++axis) CHECK(near(normal[axis] / length, cpuNormals[vertex * 3 + axis]));
        }
    };
    CHECK(ak_instance_set_layer(instance, 0, 0, 0.5f, 1.0f, 0) == AK_OK);
    const auto unskinned = positions(instance, 0);
    CHECK(ak_instance_evaluate_pose(instance) == AK_OK);
    CHECK(positions(instance, 0) == unskinned);
    comparePalette(0, bind, bindNormals);
    comparePalette(1, rigidBind, rigidNormals);
    CHECK(ak_instance_set_layer(instance, 0, -1, 0, 0, 0) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    // The instance keeps the asset data alive after the asset handle is released.
    ak_asset_destroy(asset);

    // Rest pose. glTF (x, y, z) maps to scene (z, x, y).
    std::vector<float> p = positions(instance, 0);
    CHECK_POINT(p, 0, 0, 0, 0);
    CHECK_POINT(p, 1, 0, 1, 0);
    CHECK_POINT(p, 2, 0, 0, 2);
    // Prop sits at Bone (y=1) plus its own z=1 offset: glTF (0, 1, 1).
    p = positions(instance, 1);
    CHECK_POINT(p, 0, 1, 0, 1);
    CHECK_POINT(p, 2, 1, 0, 3);

    CHECK(ak_instance_set_layer(instance, 0, 0, 0.5f, 1.0f, 1) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    p = positions(instance, 0);
    CHECK_POINT(p, 0, 0, 0, 0);
    CHECK_POINT(p, 2, 0, 0, 2.5f);
    p = positions(instance, 1);
    CHECK_POINT(p, 0, 1, 0, 1.5f);

    // Looping wraps 1.25 s to 0.25 s; clamping holds the last key.
    CHECK(ak_instance_set_layer(instance, 0, 0, 1.25f, 1.0f, 1) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    CHECK_POINT(positions(instance, 0), 2, 0, 0, 2.25f);
    CHECK(ak_instance_set_layer(instance, 0, 0, 1.25f, 1.0f, 0) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    CHECK_POINT(positions(instance, 0), 2, 0, 0, 3.0f);

    // Step keys hold until the next key time.
    CHECK(ak_instance_set_layer(instance, 0, 1, 0.45f, 1.0f, 0) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    CHECK_POINT(positions(instance, 0), 2, 0, 0, 2.0f);

    // Equal blend of Lift at 1 s (y=2) and Step at 0.5 s (y=3).
    CHECK(ak_instance_set_layer(instance, 0, 0, 1.0f, 1.0f, 0) == AK_OK);
    CHECK(ak_instance_set_layer(instance, 1, 1, 0.5f, 1.0f, 0) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    CHECK_POINT(positions(instance, 0), 2, 0, 0, 3.5f);

    // Joint matrices report the bone in scene space.
    uint32_t size = 0;
    CHECK(ak_instance_read_joint_matrices(instance, nullptr, &size) == AK_OK);
    CHECK(size == info.joint_count * 16 * sizeof(float));
    std::vector<float> joints(size / sizeof(float));
    CHECK(ak_instance_read_joint_matrices(instance, reinterpret_cast<uint8_t *>(joints.data()), &size) == AK_OK);
    CHECK(near(joints[bone * 16 + 14], 2.5f));

    ak_bounds bounds{};
    bounds.struct_size = sizeof(bounds);
    CHECK(ak_instance_get_bounds(instance, &bounds) == AK_OK);
    CHECK(near(bounds.maximum[2], 4.5f));

    std::vector<float> normals = read<float>(ak_instance_read_normals, instance, 0);
    CHECK(normals.size() == 9);
    CHECK(near(std::fabs(normals[0]), 1.0f));

    // IK chains name joints from ancestor to descendant; weight 0 or null disables one.
    ak_two_bone_ik ik{};
    ik.struct_size = sizeof(ik);
    ik.start_joint = armature;
    ik.mid_joint = bone;
    ik.end_joint = prop;
    ik.target[0] = 1.0f;
    ik.target[2] = 1.0f;
    ik.pole[1] = 1.0f;
    ik.weight = 1.0f;
    ik.soften = 1.0f;
    CHECK(ak_instance_set_ik(instance, 0, &ik) == AK_OK);
    CHECK(ak_instance_evaluate(instance) == AK_OK);
    CHECK(ak_instance_set_ik(instance, AK_MAX_IK_CHAINS, &ik) == AK_ERROR_INVALID_ARGUMENT);
    std::swap(ik.start_joint, ik.end_joint);
    CHECK(ak_instance_set_ik(instance, 0, &ik) == AK_ERROR_INVALID_ARGUMENT);
    std::swap(ik.start_joint, ik.end_joint);
    ik.soften = 0.0f;
    CHECK(ak_instance_set_ik(instance, 0, &ik) == AK_ERROR_INVALID_ARGUMENT);
    CHECK(ak_instance_set_ik(instance, 0, nullptr) == AK_OK);

    // A joint turn rides on the animated pose and carries the joint's descendants; weight 0 removes it.
    {
        auto jointOrigin = [&](int32_t joint) {
            uint32_t bytes = 0;
            CHECK(ak_instance_read_joint_matrices(instance, nullptr, &bytes) == AK_OK);
            std::vector<float> matrices(bytes / sizeof(float));
            CHECK(ak_instance_read_joint_matrices(instance, reinterpret_cast<uint8_t *>(matrices.data()), &bytes)
                == AK_OK);
            return std::array<float, 3>{matrices[joint * 16 + 12], matrices[joint * 16 + 13], matrices[joint * 16 + 14]};
        };
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto before = jointOrigin(prop);
        const float quarter = std::sqrt(0.5f);
        CHECK(ak_instance_set_joint_rotation(instance, 1, bone, 0.0f, quarter, 0.0f, quarter, 1.0f) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto turned = jointOrigin(prop);
        CHECK(!near(turned[0], before[0]) || !near(turned[1], before[1]) || !near(turned[2], before[2]));
        // Half weight lands between none and all of the turn.
        CHECK(ak_instance_set_joint_rotation(instance, 1, bone, 0.0f, quarter, 0.0f, quarter, 0.5f) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto half = jointOrigin(prop);
        CHECK(!near(half[0], turned[0]) || !near(half[2], turned[2]));
        CHECK(ak_instance_set_joint_rotation(instance, 1, bone, 0.0f, quarter, 0.0f, quarter, 0.0f) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto restored = jointOrigin(prop);
        CHECK(near(restored[0], before[0]) && near(restored[1], before[1]) && near(restored[2], before[2]));
        CHECK(ak_instance_set_joint_rotation(instance, 1, -1, 0, 0, 0, 1, 1) == AK_ERROR_INVALID_ARGUMENT);
        CHECK(ak_instance_set_joint_rotation(instance, 1, 999, 0, 0, 0, 1, 1) == AK_ERROR_INVALID_ARGUMENT);
        CHECK(ak_instance_set_joint_rotation(instance, 1, bone, 0, 0, 0, 0, 1) == AK_ERROR_INVALID_ARGUMENT);

        // Sources compose on one joint and never overwrite each other.
        CHECK(ak_instance_set_joint_rotation(instance, 1, bone, 0.0f, quarter, 0.0f, quarter, 1.0f) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto first = jointOrigin(prop);
        CHECK(ak_instance_set_joint_rotation(instance, 2, bone, quarter, 0.0f, 0.0f, quarter, 1.0f) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto both = jointOrigin(prop);
        CHECK(!near(both[0], first[0]) || !near(both[1], first[1]) || !near(both[2], first[2]));
        // Removing the first source leaves the second's turn alone, as if it had been the only one.
        CHECK(ak_instance_clear_joint_rotations(instance, 1) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto second = jointOrigin(prop);
        CHECK(!near(second[0], before[0]) || !near(second[1], before[1]) || !near(second[2], before[2]));
        CHECK(ak_instance_clear_joint_rotations(instance, 2) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto cleared = jointOrigin(prop);
        CHECK(near(cleared[0], before[0]) && near(cleared[1], before[1]) && near(cleared[2], before[2]));

        // A batch replaces its source's turns in one call, and matches the same turn set singly.
        auto record = [&](std::vector<uint8_t> &bytes, int32_t joint, float x, float y, float z, float w, float weight) {
            const float values[5] = {x, y, z, w, weight};
            const size_t at = bytes.size();
            bytes.resize(at + sizeof(joint) + sizeof(values));
            std::memcpy(bytes.data() + at, &joint, sizeof(joint));
            std::memcpy(bytes.data() + at + sizeof(joint), values, sizeof(values));
        };
        std::vector<uint8_t> batch;
        record(batch, bone, 0.0f, quarter, 0.0f, quarter, 1.0f);
        CHECK(ak_instance_set_joint_rotations(instance, 3, batch.data(), static_cast<uint32_t>(batch.size())) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto batched = jointOrigin(prop);
        CHECK(near(batched[0], turned[0]) && near(batched[1], turned[1]) && near(batched[2], turned[2]));
        // A second batch replaces the first rather than adding to it.
        std::vector<uint8_t> empty;
        CHECK(ak_instance_set_joint_rotations(instance, 3, empty.data(), 0) == AK_OK);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto emptied = jointOrigin(prop);
        CHECK(near(emptied[0], before[0]) && near(emptied[1], before[1]) && near(emptied[2], before[2]));
        // One bad record, or a size that is not whole records, changes nothing.
        CHECK(ak_instance_set_joint_rotations(instance, 3, batch.data(), static_cast<uint32_t>(batch.size())) == AK_OK);
        std::vector<uint8_t> broken = batch;
        record(broken, 999, 0.0f, 0.0f, 0.0f, 1.0f, 1.0f);
        CHECK(ak_instance_set_joint_rotations(instance, 3, broken.data(), static_cast<uint32_t>(broken.size()))
            == AK_ERROR_INVALID_ARGUMENT);
        CHECK(ak_instance_set_joint_rotations(instance, 3, batch.data(), static_cast<uint32_t>(batch.size()) - 1)
            == AK_ERROR_INVALID_ARGUMENT);
        CHECK(ak_instance_evaluate(instance) == AK_OK);
        const auto kept = jointOrigin(prop);
        CHECK(near(kept[0], turned[0]) && near(kept[1], turned[1]) && near(kept[2], turned[2]));
        CHECK(ak_instance_clear_joint_rotations(instance, 3) == AK_OK);
    }

    CHECK(ak_instance_set_layer(instance, AK_MAX_LAYERS, 0, 0, 1, 0) == AK_ERROR_INVALID_ARGUMENT);
    CHECK(ak_instance_set_layer(instance, 0, 7, 0, 1, 0) == AK_ERROR_INVALID_ARGUMENT);
    ak_instance_destroy(instance);
    CHECK(ak_instance_evaluate(instance) == AK_ERROR_INVALID_HANDLE);

    const char broken[] = "{\"asset\": {\"version\": \"2.0\"}}";
    ak_asset_handle empty{};
    CHECK(ak_asset_load_memory(reinterpret_cast<const uint8_t *>(broken), sizeof(broken) - 1, &empty)
        == AK_ERROR_IMPORT);
    CHECK(std::strlen(ak_last_error()) > 0);

    checkCreaseSmoothing();

    if (failures == 0) std::printf("animkit gltf: ok\n");
    return failures == 0 ? 0 : 1;
}
