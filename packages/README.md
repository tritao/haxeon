# Haxeon packages

| Folder | Package name | Managed API |
| --- | --- | --- |
| `platform` | `haxeon-platform` | `haxeon.platform.*` |
| `audio` | `haxeon-audio` | `haxeon.audio.*` |
| `animation` | `haxeon-animation` | `haxeon.animation.*` |
| `gpu` | `haxeon-gpu` | `haxeon.gpu.*` |
| `editor` | `haxeon-editor` | `haxeon.editor.*` |
| `ui` | `haxeon-ui` | `haxeon.ui.*` |
| `agentkit` | `haxeon-agentkit` | `haxeon.agent.*` |
| `agentkit-nativekit` | `haxeon-agentkit-nativekit` | `haxeon.agent.nativekit.*` |
| `nativekit` | `haxeon-nativekit` | none: NativeKit's native core, which the other native packages build on |

Each package here is in the `haxeon` registry under its folder's name, versioned with Haxeon (`ui = "^0.3"`), unless its
manifest says `"publish": false`; its `publish` section says what a release leaves out of it
([MANIFEST.md](../docs/reference/MANIFEST.md)). A checkout resolves them from these folders as they are.

Animation is renderer-independent; its optional `animation/native` provider builds glTF/ozz support.
Audio and GPU depend on platform. NativeKit is built once, by the `nativekit` package; UI builds on it, and audio,
credentials and filesystem each build their NativeKit module on it (`nativekit_add_module`, in
`nativekit/cmake/NativeKitPackage.cmake`), so a program or app using several of them has one NativeKit core.
UI depends on platform, GPU, editor and nativekit. The editor
package is independent of UI and native services. SceneKit remains in Materia,
including the orbit camera (`nativekit.scene.PerspectiveCamera`).

Agentkit is a headless agent runtime independent of the platform; `agentkit-nativekit` supplies its
streaming HTTP transport on NativeKit.

The `vendor/nativekit` submodule pins the native implementation. Initialize it
and UI's private dependencies with:

```sh
git submodule update --init --recursive vendor/nativekit packages/ui/native/vendor
```

Package tooling accepts `NATIVEKIT_DIR` for a separate native checkout. The C
ABI, library names, CMake targets, and generated FFI names retain their NativeKit
names. Managed platform modules formerly imported from the root now require
`haxeon.platform` imports; `nativekit.gpu` and `nativekit.ui` become
`haxeon.gpu` and `haxeon.ui`. Managed UI bindings formerly imported from the root
(such as `Color`, `Canvas`, and `LayoutFrame`) now live in `haxeon.ui`.
