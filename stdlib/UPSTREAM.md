# Upstream provenance

- Project: Haxe standard library
- Repository: https://github.com/HaxeFoundation/haxe
- Version: 4.3.7
- License: MIT (see `LICENSE`)

## Imported files

| Local path | Upstream path | Compatibility changes |
| --- | --- | --- |
| `StringBuf.hx` | `std/StringBuf.hx` | Documentation abbreviated and storage initialized explicitly; public behavior is unchanged. |
| `StringTools.hx` | `std/StringTools.hx` | Limited to `contains`, prefix/suffix checks, replacement, trimming, padding, hexadecimal conversion, and `isSpace`; runtime-backed operations use source-declared HashLink bindings. |
| `haxe/ds/ArraySort.hx` | `std/haxe/ds/ArraySort.hx` | Added explicit local types, normalized binary callback syntax, and qualified same-class helper calls for the supported subset; behavior is unchanged. |
| `haxe/ds/Either.hx` | `std/haxe/ds/Either.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
| `haxe/ds/Option.hx` | `std/haxe/ds/Option.hx` | Documentation comments abbreviated; declaration and behavior are unchanged. |
