#include "runtime.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "ozz/animation/runtime/blending_job.h"
#include "ozz/animation/runtime/ik_two_bone_job.h"
#include "ozz/animation/runtime/local_to_model_job.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/maths/simd_quaternion.h"
#include "ozz/geometry/runtime/skinning_job.h"

namespace animkit {
namespace {

ozz::math::Float4x4 toFloat4x4(const Matrix &m) {
    ozz::math::Float4x4 result;
    for (int column = 0; column < 4; ++column)
        result.cols[column] = ozz::math::simd_float4::LoadPtrU(m.data() + column * 4);
    return result;
}

void normalizeNormals(std::vector<float> &normals) {
    for (size_t v = 0; v + 2 < normals.size(); v += 3) {
        const float length = std::sqrt(normals[v] * normals[v] + normals[v + 1] * normals[v + 1]
            + normals[v + 2] * normals[v + 2]);
        if (length > 0.0f)
            for (int i = 0; i < 3; ++i) normals[v + i] /= length;
    }
}

} // namespace

Matrix identityMatrix() {
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
}

Matrix multiply(const Matrix &a, const Matrix &b) {
    Matrix result{};
    for (int column = 0; column < 4; ++column)
        for (int row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) sum += a[k * 4 + row] * b[column * 4 + k];
            result[column * 4 + row] = sum;
        }
    return result;
}

Matrix toMatrix(const ozz::math::Float4x4 &m) {
    Matrix result;
    for (int column = 0; column < 4; ++column) ozz::math::StorePtrU(m.cols[column], result.data() + column * 4);
    return result;
}

const Matrix &gltfToScene() {
    static const Matrix matrix = {0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1};
    return matrix;
}

Instance::Instance(std::shared_ptr<const Asset> asset) : asset_(std::move(asset)) {
    import_ = toFloat4x4(gltfToScene());
    sceneInverse_ = ozz::math::Invert(import_);
    for (const Skin &skin : asset_->skins) {
        std::vector<ozz::math::Float4x4> matrices;
        for (const Matrix &m : skin.inverse_bind) matrices.push_back(toFloat4x4(m));
        inverse_bind_.push_back(std::move(matrices));
    }
    const auto &skeleton = *asset_->skeleton;
    int max_tracks = 0;
    for (const Clip &clip : asset_->clips) max_tracks = std::max(max_tracks, clip.animation->num_tracks());
    for (int layer = 0; layer < kMaxLayers; ++layer) {
        contexts_[layer] = std::make_unique<ozz::animation::SamplingJob::Context>(max_tracks);
        layer_locals_[layer].resize(skeleton.num_soa_joints());
    }
    locals_.resize(skeleton.num_soa_joints());
    models_.resize(skeleton.num_joints());
    scene_models_.resize(skeleton.num_joints());
    outputs_.resize(asset_->primitives.size());
    for (size_t i = 0; i < outputs_.size(); ++i) {
        outputs_[i].positions.resize(asset_->primitives[i].positions.size());
        outputs_[i].normals.resize(asset_->primitives[i].normals.size());
    }
    evaluate();
}

namespace {

// Rotates one joint's local rotation, stored four joints to a SoA lane, by q.
void multiplyLocalRotation(std::vector<ozz::math::SoaTransform> &locals, int joint,
                           const ozz::math::SimdQuaternion &q) {
    ozz::math::SoaTransform &soa = locals[joint / 4];
    ozz::math::SimdQuaternion quaternions[4];
    ozz::math::Transpose4x4(&soa.rotation.x, &quaternions->xyzw);
    quaternions[joint & 3] = quaternions[joint & 3] * q;
    ozz::math::Transpose4x4(&quaternions->xyzw, &soa.rotation.x);
}

// A joint's local rotation, read from its SoA lane and replaced.
ozz::math::SimdQuaternion getLocalRotation(const std::vector<ozz::math::SoaTransform> &locals, int joint) {
    ozz::math::SoaTransform soa = locals[joint / 4];
    ozz::math::SimdQuaternion quaternions[4];
    ozz::math::Transpose4x4(&soa.rotation.x, &quaternions->xyzw);
    return quaternions[joint & 3];
}

void setLocalRotation(std::vector<ozz::math::SoaTransform> &locals, int joint, const ozz::math::SimdQuaternion &q) {
    ozz::math::SoaTransform &soa = locals[joint / 4];
    ozz::math::SimdQuaternion quaternions[4];
    ozz::math::Transpose4x4(&soa.rotation.x, &quaternions->xyzw);
    quaternions[joint & 3] = q;
    ozz::math::Transpose4x4(&quaternions->xyzw, &soa.rotation.x);
}

// The rotation of a model-space matrix (its scale is taken out), as a quaternion.
ozz::math::SimdQuaternion rotationOf(const ozz::math::Float4x4 &matrix) {
    namespace m = ozz::math;
    float c[3][4];
    for (int column = 0; column < 3; ++column) m::StorePtrU(matrix.cols[column], c[column]);
    for (int column = 0; column < 3; ++column) {
        const float length = std::sqrt(c[column][0] * c[column][0] + c[column][1] * c[column][1] + c[column][2] * c[column][2]);
        if (length > 1e-8f) for (int row = 0; row < 3; ++row) c[column][row] /= length;
    }
    // r[row][column]
    const float r00 = c[0][0], r10 = c[0][1], r20 = c[0][2], r01 = c[1][0], r11 = c[1][1], r21 = c[1][2],
                r02 = c[2][0], r12 = c[2][1], r22 = c[2][2];
    float x, y, z, w;
    const float trace = r00 + r11 + r22;
    if (trace > 0.0f) {
        const float s = std::sqrt(trace + 1.0f) * 2.0f;
        w = 0.25f * s; x = (r21 - r12) / s; y = (r02 - r20) / s; z = (r10 - r01) / s;
    } else if (r00 > r11 && r00 > r22) {
        const float s = std::sqrt(1.0f + r00 - r11 - r22) * 2.0f;
        w = (r21 - r12) / s; x = 0.25f * s; y = (r01 + r10) / s; z = (r02 + r20) / s;
    } else if (r11 > r22) {
        const float s = std::sqrt(1.0f + r11 - r00 - r22) * 2.0f;
        w = (r02 - r20) / s; x = (r01 + r10) / s; y = 0.25f * s; z = (r12 + r21) / s;
    } else {
        const float s = std::sqrt(1.0f + r22 - r00 - r11) * 2.0f;
        w = (r10 - r01) / s; x = (r02 + r20) / s; y = (r12 + r21) / s; z = 0.25f * s;
    }
    return m::Normalize(m::SimdQuaternion{m::simd_float4::Load(x, y, z, w)});
}

// The direction the animation bends a limb, carried onto a new start-to-target axis by the smallest
// rotation that takes the animated axis there, so it changes continuously as the target moves. A
// fixed pole cannot do this: the bend plane contains the pole and the axis, so whenever the axis
// passes the pole the plane is undefined and the elbow swings through a half turn. A limb the
// animation holds straight has no bend of its own; `fallback` is returned for it.
//
// The smallest rotation is also undefined where the new axis is the opposite of the animated one, and just short of
// it the carried bend swings through a half turn as the target moves a few millimetres; a crouched worker leaning far
// over a low surface reaches it, because its animated arm points the other way from the reach. So the bend is not
// carried by that rotation but defined at every axis by one field: the `lateral` direction (out to the limb's side)
// projected perpendicular to the axis, turned about the axis by the angle the animation's own bend makes with the
// same projection at the animated axis. It equals the animation's bend at the animated axis, it equals the carried
// bend wherever the axis moves in the plane the lateral direction is perpendicular to (a hand swinging from hanging to
// forward), and it is undefined only for an axis along `lateral`, a limb held straight out or straight across the
// body, which a reach rarely is; the carried bend serves there. (Crossing over between the two is not an option: they
// differ by the twist of the triangle the two axes and `lateral` make, which is anything up to a half turn, and a
// shortest-arc blend of bends that far apart flips.) The one cost is that a limb the animation swings out sideways
// (an arm in a turn clip) swings the field's bend with it faster than the carried bend does.
constexpr float kLateralFlatSine = 0.15f;

ozz::math::SimdFloat4 across(const ozz::math::SimdFloat4 &v, const ozz::math::SimdFloat4 &axis) {
    namespace m = ozz::math;
    return v - axis * m::SplatX(m::Dot3(v, axis));
}

// Turns a unit vector perpendicular to `axis` about it by `angle`.
ozz::math::SimdFloat4 turnAbout(const ozz::math::SimdFloat4 &v, const ozz::math::SimdFloat4 &axis, float angle) {
    namespace m = ozz::math;
    return v * m::simd_float4::Load1(std::cos(angle)) + m::Cross3(axis, v) * m::simd_float4::Load1(std::sin(angle));
}

// The signed angle about `axis` from one vector perpendicular to it to another.
float angleAbout(const ozz::math::SimdFloat4 &from, const ozz::math::SimdFloat4 &to, const ozz::math::SimdFloat4 &axis) {
    namespace m = ozz::math;
    return std::atan2(m::GetX(m::Dot3(m::Cross3(from, to), axis)), m::GetX(m::Dot3(from, to)));
}
ozz::math::SimdFloat4 animatedBend(const ozz::math::SimdFloat4 &start, const ozz::math::SimdFloat4 &mid,
                                   const ozz::math::SimdFloat4 &end, const ozz::math::SimdFloat4 &target,
                                   const ozz::math::SimdFloat4 &fallback, const ozz::math::SimdFloat4 &lateral) {
    namespace m = ozz::math;
    const m::SimdFloat4 animated_span = end - start, new_span = target - start;
    const float animated_length = m::GetX(m::Length3(animated_span));
    if (!(animated_length > 1e-6f) || !(m::GetX(m::Length3(new_span)) > 1e-6f)) return fallback;
    const m::SimdFloat4 animated_axis = animated_span / m::simd_float4::Load1(animated_length);
    const m::SimdFloat4 elbow = mid - start;
    const m::SimdFloat4 bend = elbow - animated_axis * m::SplatX(m::Dot3(elbow, animated_axis));
    if (!(m::GetX(m::Length3(bend)) > 1e-3f * animated_length)) return fallback;
    const m::SimdFloat4 new_axis = m::Normalize3(new_span);
    const m::SimdFloat4 reference_at_animated = across(lateral, animated_axis);
    const m::SimdFloat4 reference_at_new = across(lateral, new_axis);
    const float sine_animated = m::GetX(m::Length3(reference_at_animated));
    const float sine_new = m::GetX(m::Length3(reference_at_new));
    if (!(sine_animated > kLateralFlatSine) || !(sine_new > kLateralFlatSine)) {
        const m::SimdQuaternion carry = m::SimdQuaternion::FromVectors(animated_axis, new_axis);
        return m::NormalizeSafe3(m::TransformVector(carry, bend), fallback);
    }
    const m::SimdFloat4 reference_animated_unit = reference_at_animated / m::simd_float4::Load1(sine_animated);
    const m::SimdFloat4 reference_new_unit = reference_at_new / m::simd_float4::Load1(sine_new);
    const float offset = angleAbout(reference_animated_unit, m::Normalize3(bend), animated_axis);
    return m::NormalizeSafe3(turnAbout(reference_new_unit, new_axis, offset), fallback);
}

} // namespace

namespace {

bool turnBefore(const JointRotation &a, const JointRotation &b) {
    return a.source != b.source ? a.source < b.source : a.joint < b.joint;
}

} // namespace

void Instance::setJointRotation(const JointRotation &turn) {
    auto existing = std::find_if(joint_rotations.begin(), joint_rotations.end(), [&](const JointRotation &other) {
        return other.source == turn.source && other.joint == turn.joint;
    });
    if (!(turn.weight > 0.0f)) {
        if (existing != joint_rotations.end()) joint_rotations.erase(existing);
        return;
    }
    if (existing != joint_rotations.end()) {
        *existing = turn;
        return;
    }
    joint_rotations.insert(std::upper_bound(joint_rotations.begin(), joint_rotations.end(), turn, turnBefore), turn);
}

void Instance::replaceJointRotations(uint32_t source, const std::vector<JointRotation> &turns) {
    joint_rotations.erase(std::remove_if(joint_rotations.begin(), joint_rotations.end(),
                                         [source](const JointRotation &turn) { return turn.source == source; }),
                          joint_rotations.end());
    for (const JointRotation &turn : turns) setJointRotation(turn);
}

bool Instance::evaluate(bool skin) {
    const auto &skeleton = *asset_->skeleton;
    ozz::animation::BlendingJob::Layer blend_layers[kMaxLayers];
    int active = 0;
    bool valid = true;
    for (int i = 0; i < kMaxLayers; ++i) {
        const Layer &layer = layers[i];
        if (!(layer.weight > 0.0f) || layer.clip < 0) continue;
        if (layer.clip >= static_cast<int32_t>(asset_->clips.size())) {
            valid = false;
            continue;
        }
        const ozz::animation::Animation &animation = *asset_->clips[layer.clip].animation;
        const float duration = animation.duration();
        float time = layer.time;
        if (layer.loop) {
            time = std::fmod(time, duration);
            if (time < 0.0f) time += duration;
        }
        ozz::animation::SamplingJob sampling;
        sampling.animation = &animation;
        sampling.context = contexts_[i].get();
        sampling.ratio = std::clamp(time / duration, 0.0f, 1.0f);
        sampling.output = ozz::make_span(layer_locals_[i]);
        if (!sampling.Run()) {
            valid = false;
            continue;
        }
        blend_layers[active].transform = ozz::make_span(layer_locals_[i]);
        blend_layers[active].weight = layer.weight;
        ++active;
    }

    if (active == 0) {
        const auto rest = skeleton.joint_rest_poses();
        std::copy(rest.begin(), rest.end(), locals_.begin());
    } else if (active == 1) {
        std::copy(blend_layers[0].transform.begin(), blend_layers[0].transform.end(), locals_.begin());
    } else {
        ozz::animation::BlendingJob blending;
        blending.layers = ozz::span<const ozz::animation::BlendingJob::Layer>(blend_layers, active);
        blending.rest_pose = skeleton.joint_rest_poses();
        blending.output = ozz::make_span(locals_);
        blending.threshold = 1e-3f;
        if (!blending.Run()) valid = false;
    }

    for (const JointRotation &turn : joint_rotations) {
        // Blend from no turn toward the full one, along the shorter arc.
        namespace m = ozz::math;
        const float w = std::clamp(turn.weight, 0.0f, 1.0f);
        const float sign = turn.rotation[3] < 0.0f ? -1.0f : 1.0f;
        const m::SimdQuaternion blended = m::Normalize(
            m::SimdQuaternion{m::simd_float4::Load(sign * turn.rotation[0] * w, sign * turn.rotation[1] * w,
                                                   sign * turn.rotation[2] * w,
                                                   1.0f - w + sign * turn.rotation[3] * w)});
        multiplyLocalRotation(locals_, turn.joint, blended);
    }

    ozz::animation::LocalToModelJob local_to_model;
    local_to_model.skeleton = &skeleton;
    local_to_model.input = ozz::make_span(locals_);
    local_to_model.output = ozz::make_span(models_);
    if (!local_to_model.Run()) return false;
    if (!solveIk()) valid = false;
    for (size_t joint = 0; joint < models_.size(); ++joint) scene_models_[joint] = toMatrix(import_ * models_[joint]);
    if (skin)
        for (size_t primitive = 0; primitive < outputs_.size(); ++primitive) skinPrimitive(primitive);
    return valid;
}

bool Instance::validChain(int32_t start, int32_t mid, int32_t end) const {
    const auto &skeleton = *asset_->skeleton;
    const int joints = skeleton.num_joints();
    if (start < 0 || mid < 0 || end < 0 || start >= joints || mid >= joints || end >= joints)
        return false;
    const auto parents = skeleton.joint_parents();
    auto descends = [&](int32_t joint, int32_t ancestor) {
        for (int16_t parent = parents[joint]; parent >= 0; parent = parents[parent])
            if (parent == ancestor) return true;
        return false;
    };
    return descends(end, mid) && descends(mid, start);
}


bool Instance::solveIk() {
    namespace m = ozz::math;
    bool solved = true;
    for (const IkChain &chain : ik) {
        if (!(chain.weight > 0.0f)) continue;
        const m::Float4x4 &start = models_[chain.start], &mid = models_[chain.mid],
                          &end = models_[chain.end];
        const m::Float4x4 endBefore = end;
        const m::SimdFloat4 target =
            m::TransformPoint(sceneInverse_, m::simd_float4::Load3PtrU(chain.target));
        const m::SimdFloat4 requested =
            m::TransformVector(sceneInverse_, m::simd_float4::Load3PtrU(chain.pole));
        // Out to the limb's side, in the skeleton's frame: the scene's y axis, pointing at the side the limb starts on
        // (the skeleton's origin is on the body's middle).
        const m::SimdFloat4 lateral_axis =
            m::NormalizeSafe3(m::TransformVector(sceneInverse_, m::simd_float4::y_axis()), m::simd_float4::y_axis());
        const m::SimdFloat4 sideways =
            m::GetX(m::Dot3(start.cols[3], lateral_axis)) < 0.0f ? lateral_axis * m::simd_float4::Load1(-1.0f) : lateral_axis;
        // A zero pole asks for the animation's own bend direction, with the default elbow direction
        // (down and back) for a limb the animation holds straight.
        const m::SimdFloat4 pole = m::GetX(m::Length3(requested)) > 1e-6f
            ? m::Normalize3(requested)
            : animatedBend(start.cols[3], mid.cols[3], end.cols[3], target,
                           m::NormalizeSafe3(m::TransformVector(sceneInverse_,
                                                 m::simd_float4::Load(-0.4f, 0.0f, -1.0f, 0.0f)),
                                             m::simd_float4::y_axis()),
                           sideways);
        // The hinge opens about the normal of the plane the limb bends in:
        // positive rotation about lower x upper straightens the joint. A
        // straight limb has no bend plane, so its hinge follows the pole.
        const m::SimdFloat4 upper = mid.cols[3] - start.cols[3], lower = end.cols[3] - mid.cols[3];
        m::SimdFloat4 hinge = m::Cross3(lower, upper);
        const float bend = m::GetX(m::Length3(hinge));
        const float scale = m::GetX(m::Length3(upper)) * m::GetX(m::Length3(lower));
        if (!(bend > 1e-4f * scale)) {
            hinge = m::Cross3(pole, end.cols[3] - start.cols[3]);
            if (!(m::GetX(m::Length3(hinge)) > 1e-6f)) continue;
        }
        const m::SimdFloat4 mid_axis =
            m::Normalize3(m::TransformVector(m::Invert(mid), m::Normalize3(hinge)));

        m::SimdQuaternion start_correction, mid_correction;
        ozz::animation::IKTwoBoneJob job;
        job.target = target;
        job.pole_vector = pole;
        job.mid_axis = mid_axis;
        job.weight = std::clamp(chain.weight, 0.0f, 1.0f);
        job.soften = std::clamp(chain.soften, 0.0f, 1.0f);
        job.start_joint = &start;
        job.mid_joint = &mid;
        job.end_joint = &end;
        job.start_joint_correction = &start_correction;
        job.mid_joint_correction = &mid_correction;
        if (!job.Run()) {
            solved = false;
            continue;
        }
        multiplyLocalRotation(locals_, chain.start, start_correction);
        multiplyLocalRotation(locals_, chain.mid, mid_correction);
        ozz::animation::LocalToModelJob update;
        update.skeleton = asset_->skeleton.get();
        update.input = ozz::make_span(locals_);
        update.output = ozz::make_span(models_);
        update.from = chain.start;
        if (!update.Run()) solved = false;
        if (chain.keepEnd > 0.0f) {
            // Turn the end joint back toward the orientation it had in the animation: the world rotation it was
            // given, expressed in its parent's new frame, blended in from the local rotation the solve left it.
            const int parent = asset_->skeleton->joint_parents()[chain.end];
            if (parent >= 0) {
                const m::SimdQuaternion wanted = rotationOf(endBefore);
                const m::SimdQuaternion parentNow = rotationOf(models_[parent]);
                const m::SimdQuaternion desired = m::Conjugate(parentNow) * wanted;
                const m::SimdQuaternion current = getLocalRotation(locals_, chain.end);
                const float weight = std::clamp(chain.keepEnd, 0.0f, 1.0f);
                // Along the shorter arc, then normalized: a nlerp.
                const m::SimdFloat4 a = current.xyzw, b = desired.xyzw;
                const float dot = m::GetX(m::Dot4(a, b));
                const m::SimdFloat4 signedB = dot < 0.0f ? -b : b;
                const m::SimdFloat4 mixed = a * m::simd_float4::Load1(1.0f - weight) + signedB * m::simd_float4::Load1(weight);
                setLocalRotation(locals_, chain.end, m::Normalize(m::SimdQuaternion{mixed}));
                ozz::animation::LocalToModelJob endUpdate;
                endUpdate.skeleton = asset_->skeleton.get();
                endUpdate.input = ozz::make_span(locals_);
                endUpdate.output = ozz::make_span(models_);
                endUpdate.from = chain.end;
                if (!endUpdate.Run()) solved = false;
            }
        }
    }
    return solved;
}

void Instance::skinPrimitive(size_t index) {
    const Primitive &primitive = asset_->primitives[index];
    Output &output = outputs_[index];
    const int vertex_count = static_cast<int>(primitive.positions.size() / 3);
    if (primitive.skin < 0) {
        const Matrix &m = scene_models_[primitive.node_joint];
        for (int v = 0; v < vertex_count; ++v) {
            const float *p = primitive.positions.data() + v * 3;
            const float *n = primitive.normals.data() + v * 3;
            float *out_p = output.positions.data() + v * 3;
            float *out_n = output.normals.data() + v * 3;
            for (int row = 0; row < 3; ++row) {
                out_p[row] = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
                out_n[row] = m[row] * n[0] + m[4 + row] * n[1] + m[8 + row] * n[2];
            }
        }
        normalizeNormals(output.normals);
        return;
    }

    const Skin &skin = asset_->skins[primitive.skin];
    const auto &inverse_bind = inverse_bind_[primitive.skin];
    palette_.resize(skin.joints.size());
    for (size_t i = 0; i < skin.joints.size(); ++i)
        palette_[i] = import_ * models_[skin.joints[i]] * inverse_bind[i];

    ozz::geometry::SkinningJob skinning;
    skinning.vertex_count = vertex_count;
    skinning.influences_count = 4;
    skinning.joint_matrices = ozz::make_span(palette_);
    skinning.joint_indices = ozz::make_span(primitive.joint_indices);
    skinning.joint_indices_stride = sizeof(uint16_t) * 4;
    skinning.joint_weights = ozz::make_span(primitive.joint_weights);
    skinning.joint_weights_stride = sizeof(float) * 3;
    skinning.in_positions = ozz::make_span(primitive.positions);
    skinning.in_positions_stride = sizeof(float) * 3;
    skinning.in_normals = ozz::make_span(primitive.normals);
    skinning.in_normals_stride = sizeof(float) * 3;
    skinning.out_positions = ozz::make_span(output.positions);
    skinning.out_positions_stride = sizeof(float) * 3;
    skinning.out_normals = ozz::make_span(output.normals);
    skinning.out_normals_stride = sizeof(float) * 3;
    skinning.Run();
    normalizeNormals(output.normals);
}

void Instance::bounds(float minimum[3], float maximum[3]) const {
    for (int i = 0; i < 3; ++i) {
        minimum[i] = std::numeric_limits<float>::max();
        maximum[i] = -std::numeric_limits<float>::max();
    }
    for (const Output &output : outputs_)
        for (size_t v = 0; v + 2 < output.positions.size(); v += 3)
            for (int i = 0; i < 3; ++i) {
                minimum[i] = std::min(minimum[i], output.positions[v + i]);
                maximum[i] = std::max(maximum[i], output.positions[v + i]);
            }
}

} // namespace animkit
