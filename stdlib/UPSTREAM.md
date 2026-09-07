# Upstream provenance

- Project: Haxe standard library
- Repository: https://github.com/HaxeFoundation/haxe
- Version: 4.3.7
- License: MIT (see `LICENSE`)

## Imported files

| Local path | Upstream path | Compatibility changes |
| --- | --- | --- |
| `Any.hx` | `std/Any.hx` | Represented as a source alias to `Dynamic` for the supported untyped-value subset. |
| `Date.hx` | `std/Date.hx` | Limited to `now` and `getTime`; the abstract uses the project-owned native date representation. |
| `Math.hx` | `std/Math.hx` | Limited to `isNaN`; the operation uses a source-declared stable runtime binding. |
| `Reflect.hx` | `std/Reflect.hx` | Limited to `compare`; the operation uses a source-declared stable runtime binding. |
| `EReg.hx` | `std/EReg.hx` | Supports literal substring matching, case-insensitive matching, match inspection, replacement, and splitting; advanced regular-expression operators are not yet implemented. |
| `Std.hx` | `std/Std.hx` | Limited to conversion, parsing, and random helpers; `parseInt` retains the current non-nullable runtime ABI and returns `0` for invalid input. |
| `StringBuf.hx` | `std/StringBuf.hx` | Documentation abbreviated and storage initialized explicitly; public behavior is unchanged. |
| `StringTools.hx` | `std/StringTools.hx` | Limited to `contains`, prefix/suffix checks, replacement, trimming, padding, hexadecimal conversion, and `isSpace`; runtime-backed operations use source-declared HashLink bindings. |
| `Sys.hx` | `std/Sys.hx` | Limited to the currently supported process, environment, filesystem, console, and command operations; signatures retain the existing runtime ABI, with path operations routed through UTF-8 marshalling adapters. |
| `haxe/io/Bytes.hx` | `std/haxe/io/Bytes.hx` | Limited to `alloc` and `ofString`; instance operations remain compiler intrinsics over the specialized byte-buffer representation. |
| `haxe/io/BytesInput.hx` | `std/haxe/io/BytesInput.hx` | Limited to the supported primitive read operations; the source API uses a project-owned native stream representation. |
| `haxe/io/BytesOutput.hx` | `std/haxe/io/BytesOutput.hx` | Limited to the supported primitive write operations; the source API uses a project-owned native stream representation. |
| `sys/FileSystem.hx` | `std/sys/FileSystem.hx` | Limited to path queries and directory/file lifecycle operations; `fullPath` is retained as a compatibility alias for `absolutePath`, and operations use source-declared stable runtime bindings. |
| `sys/io/File.hx` | `std/sys/io/File.hx` | Limited to whole-file text and byte reads/writes, including binary reads; operations use source-declared stable runtime bindings. |
| `haxe/CallStack.hx` | `std/haxe/CallStack.hx` | Provides the portable stack-item model and deterministic empty snapshots until native stack capture is exposed. |
| `haxe/Exception.hx` | `std/haxe/Exception.hx` | Source-level exception object with message, previous-exception, native-value, and stack properties. |
| `haxe/PosInfos.hx` | `std/haxe/PosInfos.hx` | Documentation abbreviated and fields made final for the supported immutable structure subset. |
| `haxe/ValueException.hx` | `std/haxe/ValueException.hx` | Retains arbitrary values in an explicit `Exception` wrapper. |
| `haxe/ds/ArraySort.hx` | `std/haxe/ds/ArraySort.hx` | Added explicit local types, normalized binary callback syntax, and qualified same-class helper calls for the supported subset; behavior is unchanged. |
| `haxe/ds/Either.hx` | `std/haxe/ds/Either.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
| `haxe/ds/Option.hx` | `std/haxe/ds/Option.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
