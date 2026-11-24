# Reference

Look up Haxeon language features, commands, libraries and target behavior.

## Language

- [Language support](LANGUAGE_SUPPORT.md) lists supported Haxe features and differences from stock Haxe.
- [Iteration](ITERATION.md) describes what can be used in a loop or passed as an iterable.
- [Structural equality](STRUCTURAL_EQUALITY.md) explains how to declare value equality and hashing.
- [Scoped cleanup](SCOPED_CLEANUP.md) explains when `scoped` values and `defer` actions are cleaned up.
- [Key paths](KEY_PATHS.md) explains how to refer to stored fields with compiler-checked paths.

## Tools

- [CLI](CLI.md) lists the commands for creating, building and running projects.
- [Error codes](ERRORS.md) explains diagnostic messages and lists the compiler codes.
- [Manifest](MANIFEST.md) describes the settings in `haxeon.toml` and `haxeon.json`.
- [Releases](RELEASES.md) explains how to install a release and what it contains.
- [Profiling](PROFILING.md) explains how to record and read profiles.

## Libraries

- [Futures and promises](ASYNC.md) explains how to publish, observe and cancel an eventual result.
- [JSON wire format](JSON_WIRE.md) explains how to encode and decode typed values as JSON.
- [MessagePack](MESSAGEPACK.md) describes the codec, framing and schema descriptors.
- [RPC](RPC.md) explains how to declare and call typed remote methods.
- [Writing shaders](WRITING_SHADERS.md) describes shader modules and their build settings.

## Platforms and runtime

- [Live patching](LIVE_PATCHING.md) explains which edits apply to a running app and which require a reload.
- [Android](ANDROID.md) explains how to build, run and live-edit an Android app.
- [WebAssembly](WASM_BACKEND.md) describes the Wasm targets, their limits and how to host them.

## C and C++ interop

- [Calling a C or C++ library](../guides/04-calling-c-and-cpp.md) walks through building and calling a native library.
- [C and C++ header import](C_HEADER_FFI.md) explains how to import, call and audit C and C++ headers.
- [Native memory](NATIVE_MEMORY.md) explains native values, pointers and ownership.
