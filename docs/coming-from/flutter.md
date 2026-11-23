# Coming from Flutter

You can describe a UI in code, run the app in development and edit it while it runs. Flutter hot reload rebuilds the
widget tree after updating the Dart runtime. Haxeon patches compatible changes in the running VM. In the Haxeon UI
package, reading a `Signal<T>` in a view records a dependency, and a change marks the dependent view for an update.
A patch preserves live state when compatible. An edit that changes stored layout can force a module reload.
[Flutter hot reload](https://docs.flutter.dev/tools/hot-reload) · [Live editing](../guides/02-live-editing.md) · [UI basics](../guides/03-ui-basics.md)

You rewrite widgets and plugins against Haxeon's APIs. The UI guide covers layouts, controls, lists, forms and navigation.
For native APIs, you can call supported C or C++ interfaces from headers. For deployment, Haxeon can build desktop
executables and Android debug APKs. The current tooling still lacks an iOS shipping workflow and a web runner for UI apps.
The Wasm program target needs a host. [C and C++ interop](../guides/04-calling-c-and-cpp.md) · [Platform status](../guides/01-first-app.md) · [Shipping](../guides/05-shipping.md)

| In Flutter or Dart | In Haxeon |
|---|---|
| `Widget` and `build()` | Describe the view with the `ui` package's controls and layouts. |
| State fields and `setState` | Store reactive values in `Signal<T>` and assign to their `value` property. |
| `flutter run` and hot reload | Use `haxeon run --watch --live` for compatible desktop app patches. |
| `pubspec.yaml` and pub dependencies | Declare dependencies in `haxeon.toml` and resolve them with `haxeon install`. |
| `String?` and `??` | Use `Null<String>`, a null check or `??`, and turn on package checks with `nullSafety = "strict"`. |
| Platform channels or `dart:ffi` | Bind a supported C or C++ interface with the header importer. Flutter plugin APIs need a port. |
| `flutter build` for a desktop app | Use a desktop runner and `haxeon build --build-mode=release`. |

[Null safety](../learn/null-safety.md) · [Dart null safety](https://dart.dev/null-safety/understanding-null-safety) · [Project manifest](../reference/MANIFEST.md)
