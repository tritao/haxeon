#ifndef ANIMKIT_RUNTIME_HPP
#define ANIMKIT_RUNTIME_HPP

#include <memory>
#include <vector>

#include "asset.hpp"
#include "ozz/animation/runtime/sampling_job.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/maths/soa_transform.h"

namespace animkit {

enum { kMaxLayers = 4, kMaxIkChains = 4 };

struct Layer {
    int32_t clip = -1;
    float time = 0.0f;
    float weight = 0.0f;
    bool loop = true;
};

/** A turn about a joint's local axes, applied on top of its animated pose. */
struct JointRotation {
    uint32_t source = 0;
    int32_t joint = -1;
    float rotation[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    float weight = 0.0f;
};

/** A two-bone chain reaching for a scene-space target; weight 0 disables it. */
struct IkChain {
    int32_t start = -1;
    int32_t mid = -1;
    int32_t end = -1;
    float target[3] = {0.0f, 0.0f, 0.0f};
    float pole[3] = {0.0f, 0.0f, 1.0f};
    float weight = 0.0f;
    float soften = 1.0f;
    float keepEnd = 0.0f;
};

/**
 * One posed copy of an asset. Evaluation samples and blends the active clip
 * layers, computes joint transforms, and skins every primitive on the CPU.
 * All outputs are in SceneKit space (+Z up, +X forward).
 */
class Instance {
public:
    explicit Instance(std::shared_ptr<const Asset> asset);

    const Asset &asset() const { return *asset_; }
    std::array<Layer, kMaxLayers> layers;
    std::array<IkChain, kMaxIkChains> ik;
    /**
     * Turns applied to joints before inverse kinematics, at most one per source and joint, kept in order
     * of source then joint so turns of several sources on one joint compose the same way every time.
     */
    std::vector<JointRotation> joint_rotations;

    /** Sets (or, at zero weight, removes) one source's turn of a joint. */
    void setJointRotation(const JointRotation &turn);
    /** Replaces every turn of a source; turns of other sources are kept. */
    void replaceJointRotations(uint32_t source, const std::vector<JointRotation> &turns);

    /** True when start, mid, and end name joints where each is an ancestor of the next. */
    bool validChain(int32_t start, int32_t mid, int32_t end) const;

    /** Returns false when a layer names a missing clip. */
    /** Poses the instance; with `skin` off the joint matrices are updated and the deformed streams are left as they were. */
    bool evaluate(bool skin = true);

    const float *jointMatrix(int joint) const { return scene_models_[joint].data(); }
    const std::vector<float> &positions(size_t primitive) const { return outputs_[primitive].positions; }
    const std::vector<float> &normals(size_t primitive) const { return outputs_[primitive].normals; }
    void bounds(float minimum[3], float maximum[3]) const;

private:
    struct Output {
        std::vector<float> positions;
        std::vector<float> normals;
    };

    std::shared_ptr<const Asset> asset_;
    ozz::math::Float4x4 import_;
    std::vector<std::vector<ozz::math::Float4x4>> inverse_bind_; // per skin
    std::array<std::unique_ptr<ozz::animation::SamplingJob::Context>, kMaxLayers> contexts_;
    std::array<std::vector<ozz::math::SoaTransform>, kMaxLayers> layer_locals_;
    std::vector<ozz::math::SoaTransform> locals_;
    std::vector<ozz::math::Float4x4> models_;
    std::vector<Matrix> scene_models_;
    std::vector<ozz::math::Float4x4> palette_;
    std::vector<Output> outputs_;

    void skinPrimitive(size_t index);
    /** Applies every enabled IK chain to locals_ and models_. */
    bool solveIk();
    ozz::math::Float4x4 sceneInverse_;
};

} // namespace animkit

#endif
