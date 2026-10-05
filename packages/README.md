# Native integration packages

- `platform`: NativeKit platform services, managed event handling, and FFI bindings.
- `gpu`: NativeKit GPU bindings and managed graphics resources; depends on platform.

These optional libraries live outside the standard library. Existing NativeKit namespaces are preserved during extraction. Consumers must replace their NativeKit source dependency with `packages/platform` and add `packages/gpu` when using GPU bindings. UIKit and Exosuit dependency updates are a separate migration.

The `vendor/nativekit` submodule pins the native implementation revision used by package CI. Initialize it with `git submodule update --init --recursive vendor/nativekit`; package tooling uses it by default and accepts `NATIVEKIT_DIR` for a separate checkout. Public C annotations remain in NativeKit; importer headers, Haxe projection policy, generation tooling, and Haxeon integration coverage belong here.
