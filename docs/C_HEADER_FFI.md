# C header FFI import

Haxeon can use Clang to turn the ABI-visible subset of a C header into a
deterministic raw HXI description:

```sh
scripts/haxeon-ffi-import \
  --target=x86_64-linux-gnu \
  --include=/path/to/library/include \
  --output=generated/library.hxi \
  /path/to/library/include/library.h
```

The target triple is mandatory because C record sizes, alignments, and field
offsets are target-specific. Include paths may be repeated. Declarations from
the input header and those include roots are imported; declarations from system
headers are excluded.

The initial importer supports C typedefs, integer enum constants, structs,
fixed-size arrays, pointers, `const`, and non-variadic function declarations.
It maps fixed-width integer typedefs and `size_t`-family types to raw HXI
primitives. Structs carry Clang-computed `@layout` and `@offset` annotations.
Output is sorted so the same header and target produce byte-identical results.

Clang must be available as `clang`. Variadic functions and flexible array
members are rejected with declaration diagnostics instead of being assigned an
unsafe approximation.

Raw HXI is the generated ABI interchange layer. It deliberately contains no
high-level ownership, lifetime, event, or error semantics; those belong in a
small handwritten Haxe wrapper. The main Haxeon frontend does not consume this
format yet. Parser and type-checker integration is the next stage.
