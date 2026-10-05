# Haxeon packages

| Folder | Package name | Managed API |
| --- | --- | --- |
| `platform` | `haxeon-platform` | `haxeon.platform.*` |
| `audio` | `haxeon-audio` | `haxeon.audio.*` |
| `gpu` | `haxeon-gpu` | `haxeon.gpu.*` |
| `editor` | `haxeon-editor` | `haxeon.editor.*` |
| `ui` | `haxeon-ui` | `haxeon.ui.*` |

Audio and GPU depend on platform. UI depends on platform, GPU, and editor. The editor
package is independent of UI and native services. SceneKit remains in Materia,
including the orbit camera (`nativekit.scene.PerspectiveCamera`).

The `vendor/nativekit` submodule pins the native implementation. Initialize it
and UI's private dependencies with:

```sh
git submodule update --init --recursive vendor/nativekit packages/ui/vendor
```

Package tooling accepts `NATIVEKIT_DIR` for a separate native checkout. The C
ABI, library names, CMake targets, and generated FFI names retain their NativeKit
names. Managed platform modules formerly imported from the root now require
`haxeon.platform` imports; `nativekit.gpu` and `nativekit.ui` become
`haxeon.gpu` and `haxeon.ui`. Managed UI bindings formerly imported from the root
(such as `Color`, `Canvas`, and `LayoutFrame`) now live in `haxeon.ui`.
