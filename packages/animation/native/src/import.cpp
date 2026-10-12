#include "asset.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>

#include "cgltf.h"
#include "ozz/animation/offline/animation_builder.h"
#include "ozz/animation/offline/raw_animation.h"
#include "ozz/animation/offline/raw_skeleton.h"
#include "ozz/animation/offline/skeleton_builder.h"
#include "stb_image.h"

namespace animkit {
namespace {

using ozz::animation::offline::RawAnimation;
using ozz::animation::offline::RawSkeleton;

struct CgltfData {
    cgltf_data *data = nullptr;
    ~CgltfData() { cgltf_free(data); }
};

std::string resultText(cgltf_result result) {
    switch (result) {
    case cgltf_result_data_too_short: return "data too short";
    case cgltf_result_unknown_format: return "unknown format";
    case cgltf_result_invalid_json: return "invalid JSON";
    case cgltf_result_invalid_gltf: return "invalid glTF";
    case cgltf_result_invalid_options: return "invalid options";
    case cgltf_result_file_not_found: return "file not found";
    case cgltf_result_io_error: return "I/O error";
    case cgltf_result_out_of_memory: return "out of memory";
    case cgltf_result_legacy_gltf: return "glTF 1.0 is not supported";
    default: return "error " + std::to_string(static_cast<int>(result));
    }
}

ozz::math::Quaternion normalized(float x, float y, float z, float w) {
    const float length = std::sqrt(x * x + y * y + z * z + w * w);
    if (!(length > 0.0f)) return ozz::math::Quaternion::identity();
    return ozz::math::Quaternion(x / length, y / length, z / length, w / length);
}

ozz::math::Quaternion quaternionFromBasis(const float r[9]) {
    // r is column-major: r[col * 3 + row].
    const float m00 = r[0], m11 = r[4], m22 = r[8];
    const float trace = m00 + m11 + m22;
    float x, y, z, w;
    if (trace > 0.0f) {
        const float s = std::sqrt(trace + 1.0f) * 2.0f;
        w = 0.25f * s;
        x = (r[5] - r[7]) / s;
        y = (r[6] - r[2]) / s;
        z = (r[1] - r[3]) / s;
    } else if (m00 > m11 && m00 > m22) {
        const float s = std::sqrt(1.0f + m00 - m11 - m22) * 2.0f;
        w = (r[5] - r[7]) / s;
        x = 0.25f * s;
        y = (r[3] + r[1]) / s;
        z = (r[6] + r[2]) / s;
    } else if (m11 > m22) {
        const float s = std::sqrt(1.0f + m11 - m00 - m22) * 2.0f;
        w = (r[6] - r[2]) / s;
        x = (r[3] + r[1]) / s;
        y = 0.25f * s;
        z = (r[7] + r[5]) / s;
    } else {
        const float s = std::sqrt(1.0f + m22 - m00 - m11) * 2.0f;
        w = (r[1] - r[3]) / s;
        x = (r[6] + r[2]) / s;
        y = (r[7] + r[5]) / s;
        z = 0.25f * s;
    }
    return normalized(x, y, z, w);
}

ozz::math::Transform localTransform(const cgltf_node &node) {
    ozz::math::Transform transform = ozz::math::Transform::identity();
    if (node.has_matrix) {
        const float *m = node.matrix;
        transform.translation = ozz::math::Float3(m[12], m[13], m[14]);
        float scale[3];
        float basis[9];
        for (int column = 0; column < 3; ++column) {
            const float *c = m + column * 4;
            scale[column] = std::sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
            for (int row = 0; row < 3; ++row)
                basis[column * 3 + row] = scale[column] > 0.0f ? c[row] / scale[column] : 0.0f;
        }
        const float determinant = basis[0] * (basis[4] * basis[8] - basis[7] * basis[5])
            - basis[3] * (basis[1] * basis[8] - basis[7] * basis[2])
            + basis[6] * (basis[1] * basis[5] - basis[4] * basis[2]);
        if (determinant < 0.0f) {
            scale[0] = -scale[0];
            for (int row = 0; row < 3; ++row) basis[row] = -basis[row];
        }
        transform.scale = ozz::math::Float3(scale[0], scale[1], scale[2]);
        transform.rotation = quaternionFromBasis(basis);
        return transform;
    }
    if (node.has_translation)
        transform.translation = ozz::math::Float3(node.translation[0], node.translation[1], node.translation[2]);
    if (node.has_rotation)
        transform.rotation = normalized(node.rotation[0], node.rotation[1], node.rotation[2], node.rotation[3]);
    if (node.has_scale)
        transform.scale = ozz::math::Float3(node.scale[0], node.scale[1], node.scale[2]);
    return transform;
}

std::string nodeName(const cgltf_data &data, const cgltf_node &node) {
    if (node.name != nullptr && node.name[0] != '\0') return node.name;
    return "node_" + std::to_string(cgltf_node_index(&data, &node));
}

class Importer {
public:
    Importer(const cgltf_data &data, std::string base_directory, Asset &asset)
        : data_(data), base_directory_(std::move(base_directory)), asset_(asset) {}

    bool run(std::string &error) {
        if (!buildSkeleton(error)) return false;
        importImages();
        importMaterials();
        importSkins();
        importPrimitives();
        importAnimations();
        return true;
    }

private:
    const cgltf_data &data_;
    std::string base_directory_;
    Asset &asset_;
    std::vector<int32_t> joint_of_node_;
    std::vector<ozz::math::Transform> rest_of_joint_;
    bool warned_morph_ = false;

    void warn(std::string message) { asset_.warnings.push_back(std::move(message)); }

    void addRawJoint(const cgltf_node &node, RawSkeleton::Joint::Children &siblings) {
        RawSkeleton::Joint joint;
        joint.name = std::to_string(cgltf_node_index(&data_, &node)).c_str();
        joint.transform = localTransform(node);
        for (cgltf_size i = 0; i < node.children_count; ++i) addRawJoint(*node.children[i], joint.children);
        siblings.push_back(std::move(joint));
    }

    bool buildSkeleton(std::string &error) {
        RawSkeleton raw;
        const cgltf_scene *scene = data_.scene != nullptr ? data_.scene
            : (data_.scenes_count > 0 ? &data_.scenes[0] : nullptr);
        if (scene != nullptr) {
            for (cgltf_size i = 0; i < scene->nodes_count; ++i) addRawJoint(*scene->nodes[i], raw.roots);
        } else {
            for (cgltf_size i = 0; i < data_.nodes_count; ++i)
                if (data_.nodes[i].parent == nullptr) addRawJoint(data_.nodes[i], raw.roots);
        }
        if (raw.num_joints() == 0) {
            error = "glTF scene contains no nodes";
            return false;
        }
        if (raw.num_joints() > ozz::animation::Skeleton::kMaxJoints) {
            error = "glTF scene has more nodes than the skeleton limit";
            return false;
        }
        ozz::animation::offline::SkeletonBuilder builder;
        asset_.skeleton = builder(raw);
        if (!asset_.skeleton) {
            error = "failed to build skeleton";
            return false;
        }

        const int count = asset_.skeleton->num_joints();
        joint_of_node_.assign(data_.nodes_count, -1);
        rest_of_joint_.resize(count);
        asset_.joints.resize(count);
        const auto names = asset_.skeleton->joint_names();
        const auto parents = asset_.skeleton->joint_parents();
        for (int joint = 0; joint < count; ++joint) {
            const size_t node = static_cast<size_t>(std::stoul(names[joint]));
            joint_of_node_[node] = joint;
            rest_of_joint_[joint] = localTransform(data_.nodes[node]);
            asset_.joints[joint].name = nodeName(data_, data_.nodes[node]);
            asset_.joints[joint].parent = parents[joint];
        }
        return true;
    }

    void importImages() {
        asset_.images.resize(data_.images_count);
        for (cgltf_size i = 0; i < data_.images_count; ++i) {
            const cgltf_image &source = data_.images[i];
            Image &image = asset_.images[i];
            image.name = source.name != nullptr ? source.name : "image_" + std::to_string(i);
            int width = 0, height = 0, channels = 0;
            stbi_uc *pixels = nullptr;
            if (source.buffer_view != nullptr) {
                const uint8_t *bytes = cgltf_buffer_view_data(source.buffer_view);
                if (bytes != nullptr)
                    pixels = stbi_load_from_memory(bytes, static_cast<int>(source.buffer_view->size),
                        &width, &height, &channels, 4);
            } else if (source.uri != nullptr && std::strncmp(source.uri, "data:", 5) == 0) {
                const char *comma = std::strchr(source.uri, ',');
                if (comma != nullptr && std::strstr(source.uri, ";base64,") != nullptr) {
                    const std::string encoded(comma + 1);
                    size_t size = encoded.size() / 4 * 3;
                    if (!encoded.empty() && encoded.back() == '=') --size;
                    if (encoded.size() > 1 && encoded[encoded.size() - 2] == '=') --size;
                    cgltf_options options = {};
                    void *decoded = nullptr;
                    if (cgltf_load_buffer_base64(&options, size, encoded.c_str(), &decoded) == cgltf_result_success) {
                        pixels = stbi_load_from_memory(static_cast<const stbi_uc *>(decoded),
                            static_cast<int>(size), &width, &height, &channels, 4);
                        std::free(decoded);
                    }
                }
            } else if (source.uri != nullptr && !base_directory_.empty()) {
                std::string uri(source.uri);
                cgltf_decode_uri(uri.data());
                uri.resize(std::strlen(uri.c_str()));
                pixels = stbi_load((base_directory_ + uri).c_str(), &width, &height, &channels, 4);
            }
            if (pixels == nullptr) {
                warn("image '" + image.name + "' could not be decoded");
                continue;
            }
            image.width = static_cast<uint32_t>(width);
            image.height = static_cast<uint32_t>(height);
            image.rgba.assign(pixels, pixels + static_cast<size_t>(width) * height * 4);
            stbi_image_free(pixels);
        }
    }

    void importMaterials() {
        asset_.materials.resize(data_.materials_count);
        for (cgltf_size i = 0; i < data_.materials_count; ++i) {
            const cgltf_material &source = data_.materials[i];
            Material &material = asset_.materials[i];
            material.name = source.name != nullptr ? source.name : "material_" + std::to_string(i);
            if (source.has_pbr_metallic_roughness) {
                const auto &pbr = source.pbr_metallic_roughness;
                std::copy(pbr.base_color_factor, pbr.base_color_factor + 4, material.base_color);
                material.metallic = pbr.metallic_factor;
                material.roughness = pbr.roughness_factor;
                const cgltf_texture *texture = pbr.base_color_texture.texture;
                if (texture != nullptr && texture->image != nullptr) {
                    const auto image = static_cast<int32_t>(cgltf_image_index(&data_, texture->image));
                    if (!asset_.images[image].rgba.empty()) material.base_color_image = image;
                }
                if (pbr.base_color_texture.texcoord != 0)
                    warn("material '" + material.name + "' samples TEXCOORD_"
                        + std::to_string(pbr.base_color_texture.texcoord) + "; only TEXCOORD_0 is imported");
            }
            std::copy(source.emissive_factor, source.emissive_factor + 3, material.emissive);
            material.alpha_mode = source.alpha_mode == cgltf_alpha_mode_mask ? 2u
                : source.alpha_mode == cgltf_alpha_mode_blend ? 3u : 1u;
            material.alpha_cutoff = source.alpha_cutoff;
            material.double_sided = source.double_sided != 0;
        }
    }

    void importSkins() {
        asset_.skins.resize(data_.skins_count);
        for (cgltf_size i = 0; i < data_.skins_count; ++i) {
            const cgltf_skin &source = data_.skins[i];
            Skin &skin = asset_.skins[i];
            skin.joints.resize(source.joints_count);
            skin.inverse_bind.assign(source.joints_count, identityMatrix());
            for (cgltf_size j = 0; j < source.joints_count; ++j) {
                skin.joints[j] = joint_of_node_[cgltf_node_index(&data_, source.joints[j])];
                if (skin.joints[j] < 0) {
                    warn("skin joint outside the imported scene; it stays at the root");
                    skin.joints[j] = 0;
                }
                if (source.inverse_bind_matrices != nullptr)
                    cgltf_accessor_read_float(source.inverse_bind_matrices, j, skin.inverse_bind[j].data(), 16);
            }
        }
    }

    static const cgltf_accessor *attribute(const cgltf_primitive &primitive, cgltf_attribute_type type,
        cgltf_int index = 0) {
        for (cgltf_size i = 0; i < primitive.attributes_count; ++i)
            if (primitive.attributes[i].type == type && primitive.attributes[i].index == index)
                return primitive.attributes[i].data;
        return nullptr;
    }

    void importPrimitives() {
        for (cgltf_size n = 0; n < data_.nodes_count; ++n) {
            const cgltf_node &node = data_.nodes[n];
            if (node.mesh == nullptr || joint_of_node_[n] < 0) continue;
            for (cgltf_size p = 0; p < node.mesh->primitives_count; ++p)
                importPrimitive(node, *node.mesh, node.mesh->primitives[p], p);
        }
    }

    void importPrimitive(const cgltf_node &node, const cgltf_mesh &mesh, const cgltf_primitive &source,
        cgltf_size index) {
        const std::string name = (mesh.name != nullptr ? std::string(mesh.name) : nodeName(data_, node))
            + (mesh.primitives_count > 1 ? "#" + std::to_string(index) : "");
        if (source.type != cgltf_primitive_type_triangles) {
            warn("primitive '" + name + "' is not a triangle list and was skipped");
            return;
        }
        const cgltf_accessor *positions = attribute(source, cgltf_attribute_type_position);
        if (positions == nullptr || positions->count == 0) {
            warn("primitive '" + name + "' has no positions and was skipped");
            return;
        }
        if (source.targets_count > 0 && !warned_morph_) {
            warned_morph_ = true;
            warn("morph targets are not supported; meshes use their base shape");
        }

        Primitive primitive;
        primitive.name = name;
        primitive.material = source.material != nullptr
            ? static_cast<int32_t>(cgltf_material_index(&data_, source.material)) : -1;
        const cgltf_size vertex_count = positions->count;
        primitive.positions.resize(vertex_count * 3);
        cgltf_accessor_unpack_floats(positions, primitive.positions.data(), primitive.positions.size());

        if (source.indices != nullptr) {
            primitive.indices.resize(source.indices->count);
            cgltf_accessor_unpack_indices(source.indices, primitive.indices.data(), sizeof(uint32_t),
                primitive.indices.size());
        } else {
            primitive.indices.resize(vertex_count);
            for (cgltf_size i = 0; i < vertex_count; ++i) primitive.indices[i] = static_cast<uint32_t>(i);
        }
        primitive.indices.resize(primitive.indices.size() / 3 * 3);
        for (uint32_t &vertex : primitive.indices)
            if (vertex >= vertex_count) vertex = 0;

        if (const cgltf_accessor *normals = attribute(source, cgltf_attribute_type_normal);
            normals != nullptr && normals->count == vertex_count) {
            primitive.normals.resize(vertex_count * 3);
            cgltf_accessor_unpack_floats(normals, primitive.normals.data(), primitive.normals.size());
            smoothNormals(primitive);
        } else {
            generateNormals(primitive);
        }
        if (const cgltf_accessor *texcoords = attribute(source, cgltf_attribute_type_texcoord);
            texcoords != nullptr && texcoords->count == vertex_count) {
            primitive.texcoords.resize(vertex_count * 2);
            cgltf_accessor_unpack_floats(texcoords, primitive.texcoords.data(), primitive.texcoords.size());
        }

        const cgltf_accessor *joints = attribute(source, cgltf_attribute_type_joints);
        const cgltf_accessor *weights = attribute(source, cgltf_attribute_type_weights);
        if (node.skin != nullptr && joints != nullptr && weights != nullptr && joints->count == vertex_count
            && weights->count == vertex_count) {
            primitive.skin = static_cast<int32_t>(cgltf_skin_index(&data_, node.skin));
            importInfluences(primitive, *joints, *weights, node.skin->joints_count);
        } else {
            primitive.node_joint = joint_of_node_[cgltf_node_index(&data_, &node)];
        }
        asset_.primitives.push_back(std::move(primitive));
    }

    void importInfluences(Primitive &primitive, const cgltf_accessor &joints, const cgltf_accessor &weights,
        cgltf_size palette_size) {
        const cgltf_size vertex_count = joints.count;
        primitive.joint_indices.resize(vertex_count * 4);
        primitive.joint_weights.resize(vertex_count * 3);
        bool clamped = false;
        for (cgltf_size v = 0; v < vertex_count; ++v) {
            cgltf_uint joint[4] = {0, 0, 0, 0};
            float weight[4] = {0, 0, 0, 0};
            cgltf_accessor_read_uint(&joints, v, joint, 4);
            cgltf_accessor_read_float(&weights, v, weight, 4);
            float sum = 0.0f;
            for (int i = 0; i < 4; ++i) {
                if (joint[i] >= palette_size) {
                    joint[i] = 0;
                    weight[i] = 0.0f;
                    clamped = true;
                }
                weight[i] = std::max(weight[i], 0.0f);
                sum += weight[i];
            }
            if (!(sum > 0.0f)) {
                weight[0] = 1.0f;
                sum = 1.0f;
            }
            for (int i = 0; i < 4; ++i) primitive.joint_indices[v * 4 + i] = static_cast<uint16_t>(joint[i]);
            for (int i = 0; i < 3; ++i) primitive.joint_weights[v * 3 + i] = weight[i] / sum;
        }
        if (clamped) warn("primitive '" + primitive.name + "' references joints outside its skin");
    }

    /**
     * Hard-edge exports duplicate every vertex per face, which shades as
     * facets. Vertices at one position blend their normals when the authored
     * normals lie within kCreaseAngle of each other, weighted by face area;
     * sharper edges stay crisp. Vertex count, UVs, and skin weights are kept.
     */
    static void smoothNormals(Primitive &primitive) {
        constexpr float kCreaseCos = 0.5f; // cos(60 degrees)
        const auto &p = primitive.positions;
        const size_t count = p.size() / 3;
        std::vector<float> area_normals(p.size(), 0.0f);
        for (size_t t = 0; t + 2 < primitive.indices.size(); t += 3) {
            const uint32_t a = primitive.indices[t], b = primitive.indices[t + 1], c = primitive.indices[t + 2];
            const float e1[3] = {p[b * 3] - p[a * 3], p[b * 3 + 1] - p[a * 3 + 1], p[b * 3 + 2] - p[a * 3 + 2]};
            const float e2[3] = {p[c * 3] - p[a * 3], p[c * 3 + 1] - p[a * 3 + 1], p[c * 3 + 2] - p[a * 3 + 2]};
            const float n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0]};
            for (uint32_t vertex : {a, b, c})
                for (int i = 0; i < 3; ++i) area_normals[vertex * 3 + i] += n[i];
        }

        std::map<std::array<int64_t, 3>, std::vector<uint32_t>> groups;
        for (size_t v = 0; v < count; ++v) {
            std::array<int64_t, 3> key;
            for (int i = 0; i < 3; ++i) key[i] = std::llround(p[v * 3 + i] * 10000.0);
            groups[key].push_back(static_cast<uint32_t>(v));
        }

        std::vector<float> smoothed = primitive.normals;
        for (const auto &entry : groups) {
            const auto &group = entry.second;
            if (group.size() < 2) continue;
            for (uint32_t v : group) {
                const float *own = primitive.normals.data() + v * 3;
                float sum[3] = {0.0f, 0.0f, 0.0f};
                for (uint32_t w : group) {
                    const float *other = primitive.normals.data() + w * 3;
                    if (own[0] * other[0] + own[1] * other[1] + own[2] * other[2] < kCreaseCos) continue;
                    for (int i = 0; i < 3; ++i) sum[i] += area_normals[w * 3 + i];
                }
                const float length = std::sqrt(sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]);
                if (length > 0.0f)
                    for (int i = 0; i < 3; ++i) smoothed[v * 3 + i] = sum[i] / length;
            }
        }
        primitive.normals = std::move(smoothed);
    }

    static void generateNormals(Primitive &primitive) {
        const auto &p = primitive.positions;
        std::vector<float> normals(p.size(), 0.0f);
        for (size_t t = 0; t + 2 < primitive.indices.size(); t += 3) {
            const uint32_t a = primitive.indices[t], b = primitive.indices[t + 1], c = primitive.indices[t + 2];
            const float e1[3] = {p[b * 3] - p[a * 3], p[b * 3 + 1] - p[a * 3 + 1], p[b * 3 + 2] - p[a * 3 + 2]};
            const float e2[3] = {p[c * 3] - p[a * 3], p[c * 3 + 1] - p[a * 3 + 1], p[c * 3 + 2] - p[a * 3 + 2]};
            const float n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0]};
            for (uint32_t vertex : {a, b, c})
                for (int i = 0; i < 3; ++i) normals[vertex * 3 + i] += n[i];
        }
        for (size_t v = 0; v < normals.size(); v += 3) {
            const float length = std::sqrt(normals[v] * normals[v] + normals[v + 1] * normals[v + 1]
                + normals[v + 2] * normals[v + 2]);
            if (length > 0.0f) {
                for (int i = 0; i < 3; ++i) normals[v + i] /= length;
            } else {
                normals[v + 2] = 1.0f;
            }
        }
        primitive.normals = std::move(normals);
    }

    void importAnimations() {
        const int joint_count = asset_.skeleton->num_joints();
        for (cgltf_size a = 0; a < data_.animations_count; ++a) {
            const cgltf_animation &source = data_.animations[a];
            RawAnimation raw;
            raw.name = source.name != nullptr && source.name[0] != '\0' ? source.name
                : ("clip_" + std::to_string(a)).c_str();
            raw.tracks.resize(joint_count);
            float duration = 0.0f;
            bool warned_weights = false;
            for (cgltf_size c = 0; c < source.channels_count; ++c) {
                const cgltf_animation_channel &channel = source.channels[c];
                if (channel.target_node == nullptr || channel.sampler == nullptr) continue;
                const int32_t joint = joint_of_node_[cgltf_node_index(&data_, channel.target_node)];
                if (joint < 0) continue;
                if (channel.target_path == cgltf_animation_path_type_weights) {
                    if (!warned_weights) warn("clip '" + std::string(raw.name.c_str())
                        + "' animates morph weights, which are ignored");
                    warned_weights = true;
                    continue;
                }
                duration = std::max(duration, importChannel(channel, raw.tracks[joint]));
            }
            raw.duration = duration > 0.0f ? duration : 1.0f / 30.0f;
            for (int joint = 0; joint < joint_count; ++joint) {
                auto &track = raw.tracks[joint];
                const ozz::math::Transform &rest = rest_of_joint_[joint];
                if (track.translations.empty()) track.translations.push_back({0.0f, rest.translation});
                if (track.rotations.empty()) track.rotations.push_back({0.0f, rest.rotation});
                if (track.scales.empty()) track.scales.push_back({0.0f, rest.scale});
            }
            ozz::animation::offline::AnimationBuilder builder;
            Clip clip;
            clip.name = raw.name.c_str();
            clip.animation = builder(raw);
            if (!clip.animation) {
                warn("clip '" + clip.name + "' could not be built and was skipped");
                continue;
            }
            asset_.clips.push_back(std::move(clip));
        }
    }

    /** Appends the channel's keys to its track and returns the last key time. */
    static float importChannel(const cgltf_animation_channel &channel, RawAnimation::JointTrack &track) {
        const cgltf_animation_sampler &sampler = *channel.sampler;
        const cgltf_size key_count = sampler.input->count;
        if (key_count == 0) return 0.0f;
        std::vector<float> times(key_count);
        cgltf_accessor_unpack_floats(sampler.input, times.data(), key_count);
        const size_t width = channel.target_path == cgltf_animation_path_type_rotation ? 4 : 3;
        const bool cubic = sampler.interpolation == cgltf_interpolation_type_cubic_spline;
        const bool step = sampler.interpolation == cgltf_interpolation_type_step;
        std::vector<float> values(sampler.output->count * width);
        cgltf_accessor_unpack_floats(sampler.output, values.data(), values.size());
        if (sampler.output->count < key_count * (cubic ? 3 : 1)) return 0.0f;
        auto value = [&](cgltf_size key) { return values.data() + (cubic ? key * 3 + 1 : key) * width; };

        // ozz requires strictly ascending, non-negative times and interpolates
        // linearly: step keys become a hold key just before each change, and
        // cubic spline keys keep their values without tangents.
        std::vector<std::pair<float, const float *>> keys;
        for (cgltf_size k = 0; k < key_count; ++k) {
            const float time = std::max(times[k], 0.0f);
            if (!keys.empty() && time <= keys.back().first) continue;
            if (step && !keys.empty()) {
                const float hold = time - std::min(1e-4f, (time - keys.back().first) * 0.5f);
                keys.push_back({hold, keys.back().second});
            }
            keys.push_back({time, value(k)});
        }
        switch (channel.target_path) {
        case cgltf_animation_path_type_translation:
            for (const auto &[time, v] : keys) track.translations.push_back({time, ozz::math::Float3(v[0], v[1], v[2])});
            break;
        case cgltf_animation_path_type_scale:
            for (const auto &[time, v] : keys) track.scales.push_back({time, ozz::math::Float3(v[0], v[1], v[2])});
            break;
        case cgltf_animation_path_type_rotation: {
            ozz::math::Quaternion previous = ozz::math::Quaternion::identity();
            for (size_t k = 0; k < keys.size(); ++k) {
                ozz::math::Quaternion q = normalized(keys[k].second[0], keys[k].second[1], keys[k].second[2],
                    keys[k].second[3]);
                if (k > 0 && q.x * previous.x + q.y * previous.y + q.z * previous.z + q.w * previous.w < 0.0f)
                    q = ozz::math::Quaternion(-q.x, -q.y, -q.z, -q.w);
                track.rotations.push_back({keys[k].first, q});
                previous = q;
            }
            break;
        }
        default: return 0.0f;
        }
        return keys.back().first;
    }
};

std::unique_ptr<Asset> finish(cgltf_result result, cgltf_data *data, const cgltf_options &options,
    const char *path, std::string base_directory, std::string &error) {
    CgltfData owned;
    owned.data = data;
    if (result != cgltf_result_success) {
        error = "failed to parse glTF: " + resultText(result);
        return nullptr;
    }
    if (path == nullptr) {
        for (cgltf_size i = 0; i < data->buffers_count; ++i) {
            const char *uri = data->buffers[i].uri;
            if (uri != nullptr && std::strncmp(uri, "data:", 5) != 0) {
                error = "glTF loaded from memory references external buffer '" + std::string(uri) + "'";
                return nullptr;
            }
        }
    }
    result = cgltf_load_buffers(&options, data, path);
    if (result != cgltf_result_success) {
        error = "failed to load glTF buffers: " + resultText(result);
        return nullptr;
    }
    result = cgltf_validate(data);
    if (result != cgltf_result_success) {
        error = "glTF validation failed: " + resultText(result);
        return nullptr;
    }
    auto asset = std::make_unique<Asset>();
    Importer importer(*data, std::move(base_directory), *asset);
    if (!importer.run(error)) return nullptr;
    return asset;
}

} // namespace

std::unique_ptr<Asset> loadGltfFile(const std::string &path, std::string &error) {
    cgltf_options options = {};
    cgltf_data *data = nullptr;
    const cgltf_result result = cgltf_parse_file(&options, path.c_str(), &data);
    const size_t slash = path.find_last_of("/\\");
    const std::string directory = slash == std::string::npos ? "./" : path.substr(0, slash + 1);
    return finish(result, data, options, path.c_str(), directory, error);
}

std::unique_ptr<Asset> loadGltfMemory(const void *bytes, size_t size, std::string &error) {
    cgltf_options options = {};
    cgltf_data *data = nullptr;
    const cgltf_result result = cgltf_parse(&options, bytes, size, &data);
    // Without a path, cgltf_load_buffers resolves only GLB and data: buffers.
    return finish(result, data, options, nullptr, std::string(), error);
}

} // namespace animkit
