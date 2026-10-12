# Haxeon animation

Renderer-independent glTF import and skeletal animation, extracted from Materia's AnimKit and HumanKit at
`5aa81d68dcac35080528a157dc6a72aa5eb94520` (2026-10-12). Managed APIs are `haxeon.animation.*`
and `haxeon.animation.rig.*`. The C ABI (`ak_*`), generated `AnimKitNative` interface and
`animkit_core` library name retain their existing names.

## Packages

- `haxeon-animation`: AnimationAsset, AnimationInstance, ClipPlayer, and humanoid rig/pose helpers.
- `haxeon-animation-native`: optional standalone CMake native provider. Applications with an aggregate
  native build can instead add `native/` and link `animkit_core` themselves.

Neither package depends on a renderer, GPU, platform, SceneKit, or a simulation library. Rendering adapters,
locomotion controllers, gameplay, HumanKit jobs and facility simulation stay in their applications.
The extracted rig helpers cover standard bones, Quaternius/UAL/Mixamo mapping, landmarks and hand frames.

```haxe
import haxeon.animation.AnimationAsset;
import haxeon.animation.AnimationInstance;
import haxeon.animation.ClipPlayer;

var asset = AnimationAsset.load("character.glb");
var instance = new AnimationInstance(asset);
var player = new ClipPlayer(instance);
player.playNamed("walk");
player.pose(seconds);                       // advance and evaluate bones, without CPU skinning
var matrices = instance.readSkinMatrices(0); // renderer uploads these to its own palette buffer/texture
```

The importer uses cgltf, stb_image and ozz-animation; their exact submodule pins and licenses are in
[native/THIRD_PARTY.md](native/THIRD_PARTY.md). Initialize dependencies from the Haxeon root:

```sh
git submodule update --init --recursive packages/animation/native/vendor
```

## Renderer contract

Source glTF bind positions/normals, uint16x4 palette joint indices, float32x4 weights,
uint32 triangle indices and UVs come from AnimationAsset. These source streams are immutable.
`readSkinJoints` maps palette slots to skeleton joints, and `readInverseBindMatrices` exposes the
per-primitive inverse binds. Joint indices are palette indices, not skeleton joint indices.

`readSkinMatrices(primitive)` returns column-major float32 4x4 matrices in palette order:
axis conversion × animated model joint × inverse bind. They transform source bind vertices into
model space (+Z up, +X forward, metres). Multiply by the application's world root afterward.
Rigid primitives return one owning-joint matrix and have no weight/index streams. Different skins
may have different palettes even when they share a skeleton.

`readJointMatrices` returns model joint frames without inverse binds, suitable for landmarks and
attachments. Do not use them directly as skinning matrices. Both matrix reads update after pose-only
evaluation. `evaluate()` additionally CPU-skins meshes; `bounds()` and deformed vertex reads describe
the most recent full evaluation, so GPU adapters must provide their own conservative animated bounds.

ClipPlayer provides crossfades and one whole-body overlay over four native blend layers.
Two-bone IK and source-ordered procedural joint rotations run after clip blending.
Joint masks, track priorities, markers, root-motion extraction, GPU shaders, baked crowd clips and
animation LOD are not provided here. Cubic-spline import drops tangents; morph targets and several
material extensions are unsupported and reported through asset warnings.

## Ownership

Dispose assets and instances explicitly. Instances keep native asset data alive after the managed asset
handle is disposed; static asset reads require a live asset handle. CPU and GPU adapters own their render
resources separately. Read methods return copied Bytes, not borrowed pointers.

## Validation

From the Haxeon root:

```sh
cmake -S packages/animation/native -B build/animation-native -GNinja -DCMAKE_BUILD_TYPE=Debug
cmake --build build/animation-native
ctest --test-dir build/animation-native --output-on-failure
scripts/haxeon run --project packages/animation/tests/haxeon.json
packages/animation/native/tools/check-hxi.sh
```

The native suite covers import, blending, IK, procedural rotations, lifetime/error handling and
shader-equivalent deformation using the public bind streams and skin palettes. The renderer-free Haxe
smoke covers playback, crossfade, pose-only evaluation, buffer reads, ownership and humanoid mapping/landmarks.
The small Kenney test fixture retains its CC0 license; production characters stay with their applications.
