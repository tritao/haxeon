#ifndef ANIMKIT_ASSET_HPP
#define ANIMKIT_ASSET_HPP

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/memory/unique_ptr.h"

namespace animkit {

using Matrix = std::array<float, 16>; // column-major, column vectors

Matrix identityMatrix();
Matrix multiply(const Matrix &a, const Matrix &b);
Matrix toMatrix(const ozz::math::Float4x4 &m);

/**
 * glTF is +Y up with models facing +Z. SceneKit is +Z up and +X forward, so
 * glTF +X, +Y, and +Z map to scene +Y, +Z, and +X respectively.
 */
const Matrix &gltfToScene();

struct Joint {
    std::string name;
    int32_t parent = -1;
};

/**
 * One drawable glTF mesh primitive placed by one node. Positions and normals
 * are stored in the space the joint palette maps into scene space: skin bind
 * space for skinned primitives, the owning node's local space for rigid ones.
 */
struct Primitive {
    std::string name;
    int32_t material = -1;
    int32_t skin = -1; // index into Asset::skins, or -1 for a rigid primitive
    int32_t node_joint = -1; // rigid primitives follow this joint
    std::vector<float> positions; // xyz
    std::vector<float> normals; // xyz; generated when missing, smoothed across split vertices
    std::vector<float> texcoords; // uv, empty when absent
    std::vector<uint32_t> indices;
    std::vector<uint16_t> joint_indices; // 4 per vertex, into the skin palette
    std::vector<float> joint_weights; // 3 per vertex; ozz derives the fourth
};

struct Skin {
    std::vector<int32_t> joints; // skeleton joint per palette entry
    std::vector<Matrix> inverse_bind;
};

struct Material {
    std::string name;
    float base_color[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    float metallic = 1.0f;
    float roughness = 1.0f;
    float emissive[3] = {0.0f, 0.0f, 0.0f};
    uint32_t alpha_mode = 1; // 1 opaque, 2 mask, 3 blend (matches SceneKit)
    float alpha_cutoff = 0.5f;
    bool double_sided = false;
    int32_t base_color_image = -1;
};

struct Image {
    std::string name;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgba; // top row first
};

struct Clip {
    std::string name;
    ozz::unique_ptr<ozz::animation::Animation> animation;
};

struct Asset {
    std::vector<Joint> joints; // ozz skeleton order
    ozz::unique_ptr<ozz::animation::Skeleton> skeleton;
    std::vector<Primitive> primitives;
    std::vector<Skin> skins;
    std::vector<Material> materials;
    std::vector<Image> images;
    std::vector<Clip> clips;
    std::vector<std::string> warnings;
};

/** Loads a .gltf or .glb file. On failure returns null and sets error. */
std::unique_ptr<Asset> loadGltfFile(const std::string &path, std::string &error);
/** Loads a self-contained .glb or .gltf document from memory. */
std::unique_ptr<Asset> loadGltfMemory(const void *data, size_t size, std::string &error);

} // namespace animkit

#endif
