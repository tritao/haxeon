# Upstream provenance

- Project: Haxe standard library
- Repository: https://github.com/HaxeFoundation/haxe
- Version: 4.3.7
- License: MIT (see `LICENSE`)

## Imported files

| Local path | Upstream path | Compatibility changes |
| --- | --- | --- |
| `Date.hx` | `std/Date.hx` | Limited to `now` and `getTime`; the abstract uses the project-owned native date representation. |
| `Math.hx` | `std/Math.hx` | Limited to `isNaN`; the operation uses a source-declared stable runtime binding. |
| `Reflect.hx` | `std/Reflect.hx` | Limited to `compare`; the operation uses a source-declared stable runtime binding. |
| `Std.hx` | `std/Std.hx` | Limited to conversion, parsing, and random helpers; `parseInt` retains the current non-nullable runtime ABI and returns `0` for invalid input. |
| `StringBuf.hx` | `std/StringBuf.hx` | Documentation abbreviated and storage initialized explicitly; public behavior is unchanged. |
| `StringTools.hx` | `std/StringTools.hx` | Limited to `contains`, prefix/suffix checks, replacement, trimming, padding, hexadecimal conversion, and `isSpace`; runtime-backed operations use source-declared HashLink bindings. |
| `Sys.hx` | `std/Sys.hx` | Limited to the currently supported process, environment, filesystem, console, and command operations; signatures retain the existing runtime ABI, with path operations routed through UTF-8 marshalling adapters. |
| `haxe/io/Bytes.hx` | `std/haxe/io/Bytes.hx` | Limited to `alloc` and `ofString`; instance operations remain compiler intrinsics over the specialized byte-buffer representation. |
| `sys/FileSystem.hx` | `std/sys/FileSystem.hx` | Limited to existence, directory, and full-path queries; operations use source-declared stable runtime bindings. |
| `sys/io/File.hx` | `std/sys/io/File.hx` | Limited to whole-file text and byte reads/writes; operations use source-declared stable runtime bindings. |
| `haxe/ds/ArraySort.hx` | `std/haxe/ds/ArraySort.hx` | Added explicit local types, normalized binary callback syntax, and qualified same-class helper calls for the supported subset; behavior is unchanged. |
| `haxe/ds/Either.hx` | `std/haxe/ds/Either.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
| `haxe/ds/Option.hx` | `std/haxe/ds/Option.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
