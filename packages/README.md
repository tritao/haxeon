# Native integration packages

- `platform`: NativeKit platform services, managed event handling, and FFI bindings.
- `gpu`: NativeKit GPU bindings and managed graphics resources; depends on platform.

These optional libraries live outside the standard library. Existing NativeKit namespaces are preserved during extraction. Consumers must replace their NativeKit source dependency with `packages/platform` and add `packages/gpu` when using GPU bindings. UIKit and Exosuit dependency updates are a separate migration.

`nativekit.lock` records the native implementation revision used by package CI. Public C annotations remain in NativeKit; importer headers, Haxe projection policy, generation tooling, and Haxeon integration coverage belong here.
