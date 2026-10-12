#ifndef ANIMKIT_H
#define ANIMKIT_H

#include <stdint.h>

#if defined(__clang__)
#define AK_OUT __attribute__((annotate("hxi:out")))
#define AK_INOUT __attribute__((annotate("hxi:inout")))
#define AK_OWNED __attribute__((annotate("hxi:owned")))
#define AK_HANDLE __attribute__((annotate("hxi:handle")))
#define AK_HANDLE_DESTROY(symbol) __attribute__((annotate("hxi:handle_destroy")))
#define AK_IN_ARRAY(count) __attribute__((annotate("hxi:in_array")))
#define AK_OUT_BUFFER(size) __attribute__((annotate("hxi:out_buffer")))
#define AK_UTF8 __attribute__((annotate("hxi:utf8")))
#define AK_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#define AK_BOOL32 __attribute__((annotate("hxi:bool32")))
#define AK_STRUCT_SIZE __attribute__((annotate("hxi:struct_size")))
#else
#define AK_OUT
#define AK_INOUT
#define AK_OWNED
#define AK_HANDLE
#define AK_HANDLE_DESTROY(symbol)
#define AK_IN_ARRAY(count)
#define AK_OUT_BUFFER(size)
#define AK_UTF8
#define AK_RETURNS_BORROWED_UTF8
#define AK_BOOL32
#define AK_STRUCT_SIZE
#endif

#if defined(_WIN32)
#if defined(AK_STATIC)
#define AK_API
#elif defined(AK_BUILDING_LIBRARY)
#define AK_API __declspec(dllexport)
#else
#define AK_API __declspec(dllimport)
#endif
#define AK_CALL __cdecl
#else
#define AK_API __attribute__((visibility("default")))
#define AK_CALL
#endif

/*
 * AnimKit imports glTF 2.0 assets and poses them with ozz-animation.
 *
 * Every node of the asset's default scene becomes a skeleton joint, so rigid
 * meshes, skinned meshes, and animated props share one pose. Outputs are in
 * SceneKit space: right-handed, +Z up, +X forward, metres. glTF +X, +Y, and
 * +Z map to scene +Y, +Z, and +X, so a glTF character facing +Z faces +X.
 *
 * Skinning runs on the CPU. Read an instance's deformed positions and normals
 * after ak_instance_evaluate and publish them as geometry streams.
 *
 * Bulk reads use a two-call buffer contract: call with a null buffer to get
 * the byte size, then again with that capacity. Vertex data is packed
 * little-endian float32, indices are packed uint32, and joint matrices are
 * column-major float32 4x4 matrices.
 */

#ifdef __cplusplus
extern "C" {
#endif

enum { AK_API_VERSION = 1, AK_MAX_LAYERS = 4, AK_MAX_IK_CHAINS = 4 };
typedef int32_t ak_result;
enum {
    AK_OK = 0,
    AK_ERROR_INVALID_ARGUMENT = -1,
    AK_ERROR_INVALID_HANDLE = -2,
    AK_ERROR_OUT_OF_MEMORY = -3,
    AK_ERROR_IMPORT = -4,
    AK_ERROR_BUFFER_TOO_SMALL = -5
};

/** Opaque registry identity; only AnimKit may interpret id. */
typedef struct ak_asset_handle { uint32_t id; } ak_asset_handle
    AK_HANDLE AK_HANDLE_DESTROY(ak_asset_destroy);
typedef struct ak_instance_handle { uint32_t id; } ak_instance_handle
    AK_HANDLE AK_HANDLE_DESTROY(ak_instance_destroy);

typedef struct ak_asset_info {
    uint32_t struct_size AK_STRUCT_SIZE;
    uint32_t joint_count;
    uint32_t primitive_count;
    uint32_t material_count;
    uint32_t image_count;
    uint32_t clip_count;
    uint32_t warning_count;
} ak_asset_info;

typedef struct ak_primitive_info {
    uint32_t struct_size AK_STRUCT_SIZE;
    uint32_t vertex_count;
    uint32_t index_count;
    /** Material index, or -1 for the default material. */
    int32_t material;
    uint32_t skinned AK_BOOL32;
    uint32_t has_texcoords AK_BOOL32;
    /** Joint a rigid primitive follows, or -1 for a skinned primitive. */
    int32_t joint;
} ak_primitive_info;

typedef struct ak_material_info {
    uint32_t struct_size AK_STRUCT_SIZE;
    float base_color[4];
    float metallic;
    float roughness;
    float emissive[3];
    /** 1 opaque, 2 mask, 3 blend; the same values as SceneKit's alpha modes. */
    uint32_t alpha_mode;
    float alpha_cutoff;
    uint32_t double_sided AK_BOOL32;
    /** Decoded image index, or -1 when there is no usable base color texture. */
    int32_t base_color_image;
} ak_material_info;

typedef struct ak_image_info {
    uint32_t struct_size AK_STRUCT_SIZE;
    uint32_t width;
    uint32_t height;
} ak_image_info;

typedef struct ak_bounds {
    uint32_t struct_size AK_STRUCT_SIZE;
    float minimum[3];
    float maximum[3];
} ak_bounds;

/**
 * A two-bone inverse kinematics chain, such as shoulder, elbow, and wrist,
 * solved after the layers blend: the end joint moves to reach target and the
 * middle joint points in the direction pole (a direction, not a position); a zero pole leaves the bend to the
 * animation, carrying the direction the animated pose bends the limb onto the new reach. The joints must be
 * ancestors in that order but need not be direct parents. Positions are in scene space. weight blends
 * from the animated pose (0, which disables the chain) to the solution (1);
 * soften in (0, 1] eases the chain before it straightens, 1 for none.
 * keep_end_rotation in [0, 1] turns the end joint back toward the orientation it had before the solve, in model
 * space (0 leaves it turned with the shin and the rest of the chain, 1 restores it): a foot reached to a spot
 * keeps lying flat on the floor instead of tilting with the leg.
 */
typedef struct ak_two_bone_ik {
    uint32_t struct_size AK_STRUCT_SIZE;
    int32_t start_joint;
    int32_t mid_joint;
    int32_t end_joint;
    float target[3];
    float pole[3];
    float weight;
    float soften;
    float keep_end_rotation;
} ak_two_bone_ik;

/** Returns this thread's last load failure, or an empty string. */
AK_API const char *AK_CALL ak_last_error(void) AK_RETURNS_BORROWED_UTF8;

/** Loads a .gltf or .glb file; external buffers and images resolve beside it. */
AK_API ak_result AK_CALL ak_asset_load_file(const char *path AK_UTF8,
    ak_asset_handle *out_asset AK_OUT AK_OWNED);
/** Loads a GLB or a .gltf document whose buffers are embedded data URIs. */
AK_API ak_result AK_CALL ak_asset_load_memory(const uint8_t *data AK_IN_ARRAY(size), uint32_t size,
    ak_asset_handle *out_asset AK_OUT AK_OWNED);
/** Releases the handle; instances created from the asset keep its data alive. */
AK_API void AK_CALL ak_asset_destroy(ak_asset_handle asset);

AK_API ak_result AK_CALL ak_asset_get_info(ak_asset_handle asset, ak_asset_info *out_info);
/** Non-fatal import diagnostics, such as skipped primitives or undecodable images. */
AK_API const char *AK_CALL ak_asset_warning(ak_asset_handle asset, uint32_t index) AK_RETURNS_BORROWED_UTF8;

/** Joint names are the glTF node names, or node_<index> for unnamed nodes. */
AK_API const char *AK_CALL ak_asset_joint_name(ak_asset_handle asset, uint32_t joint) AK_RETURNS_BORROWED_UTF8;
/** Parent joint index, or -1 for a root or an invalid query. Parents precede children. */
AK_API int32_t AK_CALL ak_asset_joint_parent(ak_asset_handle asset, uint32_t joint);
/** Returns the joint index with this name, or -1. */
AK_API int32_t AK_CALL ak_asset_find_joint(ak_asset_handle asset, const char *name AK_UTF8);

AK_API ak_result AK_CALL ak_asset_get_primitive(ak_asset_handle asset, uint32_t primitive,
    ak_primitive_info *out_info);
AK_API const char *AK_CALL ak_asset_primitive_name(ak_asset_handle asset, uint32_t primitive)
    AK_RETURNS_BORROWED_UTF8;
/** Packed uint32 triangle indices. */
AK_API ak_result AK_CALL ak_asset_read_indices(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Packed float32 UV pairs with glTF's top-left origin; empty without texcoords. */
AK_API ak_result AK_CALL ak_asset_read_texcoords(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);

/** Packed float32 xyz bind positions in source glTF space. */
AK_API ak_result AK_CALL ak_asset_read_bind_positions(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Packed float32 xyz bind normals in source glTF space. */
AK_API ak_result AK_CALL ak_asset_read_bind_normals(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Packed uint16x4 indices into this primitive's skin palette; empty for rigid meshes. */
AK_API ak_result AK_CALL ak_asset_read_joint_indices(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Packed float32x4 normalized weights; empty for rigid meshes. */
AK_API ak_result AK_CALL ak_asset_read_joint_weights(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Packed int32 skeleton joint indices in palette order; the owning joint for rigid meshes. */
AK_API ak_result AK_CALL ak_asset_read_skin_joints(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Column-major float32 4x4 inverse binds in palette order; identity for rigid meshes. */
AK_API ak_result AK_CALL ak_asset_read_inverse_bind_matrices(ak_asset_handle asset, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);

AK_API ak_result AK_CALL ak_asset_get_material(ak_asset_handle asset, uint32_t material,
    ak_material_info *out_info);
AK_API const char *AK_CALL ak_asset_material_name(ak_asset_handle asset, uint32_t material)
    AK_RETURNS_BORROWED_UTF8;

AK_API ak_result AK_CALL ak_asset_get_image(ak_asset_handle asset, uint32_t image, ak_image_info *out_info);
/** Decoded RGBA8 pixels, top row first. */
AK_API ak_result AK_CALL ak_asset_read_image(ak_asset_handle asset, uint32_t image,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);

AK_API const char *AK_CALL ak_asset_clip_name(ak_asset_handle asset, uint32_t clip) AK_RETURNS_BORROWED_UTF8;
/** Clip duration in seconds, or 0 for an invalid query. */
AK_API float AK_CALL ak_asset_clip_duration(ak_asset_handle asset, uint32_t clip);
/** Returns the clip index with this name, or -1. */
AK_API int32_t AK_CALL ak_asset_find_clip(ak_asset_handle asset, const char *name AK_UTF8);

/** Creates a posed copy at the rest pose, already evaluated. */
AK_API ak_result AK_CALL ak_instance_create(ak_asset_handle asset,
    ak_instance_handle *out_instance AK_OUT AK_OWNED);
AK_API void AK_CALL ak_instance_destroy(ak_instance_handle instance);

/**
 * Sets one of AK_MAX_LAYERS blend layers. A layer contributes when its clip is
 * valid and its weight is positive; weights are normalized across layers. Time
 * is in seconds and wraps when loop is non-zero, otherwise it clamps. With no
 * contributing layer the instance takes the rest pose.
 */
AK_API ak_result AK_CALL ak_instance_set_layer(ak_instance_handle instance, uint32_t layer, int32_t clip,
    float time, float weight, uint32_t loop AK_BOOL32);
/**
 * Sets one of AK_MAX_IK_CHAINS inverse kinematics chains, applied in order by
 * the next evaluation. A null ik or zero weight disables the chain.
 */
AK_API ak_result AK_CALL ak_instance_set_ik(ak_instance_handle instance, uint32_t chain,
    const ak_two_bone_ik *ik);
/**
 * Turns one joint by a rotation (x, y, z, w) about its own local axes, on top of its animated pose and
 * before inverse kinematics, so the turn carries the joint's children: fingers curl, a spine leans. The
 * rotation is normalized; weight in (0, 1] blends from no turn to all of it. A zero weight removes the
 * turn. `source` names who is asking: a source has at most one turn per joint, and turns of different
 * sources on the same joint compose, lowest source first, so two features never overwrite each other.
 * A turn stays until it is removed.
 */
AK_API ak_result AK_CALL ak_instance_set_joint_rotation(ak_instance_handle instance, uint32_t source,
    int32_t joint, float x, float y, float z, float w, float weight);
/**
 * Replaces every turn of one source at once, so a caller turning many joints (a hand of fingers) crosses
 * the boundary once. data holds size / 24 records, each little-endian: an int32 joint, then float32 x, y,
 * z, w and weight. Turns of other sources are kept. Nothing changes when size is not a multiple of 24 or
 * any record is invalid; records with no weight are skipped.
 */
AK_API ak_result AK_CALL ak_instance_set_joint_rotations(ak_instance_handle instance, uint32_t source,
    const uint8_t *data AK_IN_ARRAY(size), uint32_t size);
/** Removes every turn of one source. */
AK_API ak_result AK_CALL ak_instance_clear_joint_rotations(ak_instance_handle instance, uint32_t source);
/** Samples, blends, solves inverse kinematics, and skins the current layers. */
AK_API ak_result AK_CALL ak_instance_evaluate(ak_instance_handle instance);
/**
 * Samples, blends, and solves inverse kinematics as ak_instance_evaluate does, and updates the joint matrices, but
 * does not skin: the deformed positions and normals stay as the last full evaluation left them. For measuring a pose
 * (where a hand would be if a limb were released) without paying for geometry nobody will see.
 */
AK_API ak_result AK_CALL ak_instance_evaluate_pose(ak_instance_handle instance);

/** Deformed float32 xyz positions in scene space. */
AK_API ak_result AK_CALL ak_instance_read_positions(ak_instance_handle instance, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Deformed unit float32 xyz normals in scene space. */
AK_API ak_result AK_CALL ak_instance_read_normals(ak_instance_handle instance, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** One scene-space model matrix per joint, in joint order. */
AK_API ak_result AK_CALL ak_instance_read_joint_matrices(ak_instance_handle instance,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);
/** Axis-aligned bounds of every deformed primitive in scene space. */
/**
 * Column-major float32 4x4 skin matrices for a primitive, in its palette order.
 * Each maps source bind vertices into Z-up, X-forward model space, including inverse bind.
 * A rigid primitive returns its owning joint's model matrix. Updated by pose-only evaluation.
 */
AK_API ak_result AK_CALL ak_instance_read_skin_matrices(ak_instance_handle instance, uint32_t primitive,
    uint8_t *data AK_OUT_BUFFER(size), uint32_t *size AK_INOUT);

AK_API ak_result AK_CALL ak_instance_get_bounds(ak_instance_handle instance, ak_bounds *out_bounds);

#ifdef __cplusplus
}
#endif

#endif
