# C header FFI import

Haxeon can use Clang to turn the ABI-visible subset of a C header into a
deterministic raw HXI description:

```sh
scripts/haxeon-ffi-import \
  --target=x86_64-linux-gnu \
  --library=nativekit \
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
Plain C integer types retain ABI-specific names such as `c_int` and `c_long`;
they are not incorrectly assumed to have a platform-independent width. The
optional library name becomes interface-level `@library` metadata.

Pass one or more generated interfaces to the compiler with repeatable options:

```sh
haxeon-compiler \
  --ffi-interface=generated/nativekit.hxi \
  --entry=app.Main \
  sources.manifest
```

Interfaces are parsed and registered before source loading. Their names must be
unique, and the registered set becomes immutable after the first compilation,
matching the existing native-table stability rule for live modules.

The ABI classifier currently recognizes x86, x86-64, ARM, AArch64, RISC-V 64,
and WebAssembly target triples. It preserves the Windows LLP64 distinction
(`c_long` is 32-bit even with 64-bit pointers), represents plain `c_char`
without inventing a signedness, and resolves function symbols into explicit
integer, floating-point, pointer, or aggregate ABI values. Opaque types may
only be used behind pointers.

Clang must be available as `clang`. Variadic functions and flexible array
members are rejected with declaration diagnostics instead of being assigned an
unsafe approximation.

Raw HXI is the generated ABI interchange layer. It deliberately contains no
high-level ownership, lifetime, event, or error semantics; those belong in a
small handwritten Haxe wrapper. Haxeon parses and loads it into a validated ABI
model, including opaque types and `@symbol`/`@leaf` function metadata. Imported
declarations are not source-visible yet; semantic projection and lowering are
the next stage.

## Native call runtime

The runtime has a separate ordinary-C call bridge built on libffi. This is not
the HashLink `@:hlNative` ABI. `runtime.NativeLibrary` explicitly opens and
closes a dynamic library, resolves a `runtime.NativeFunction` with a fixed
signature, and invokes it through native-endian eight-byte value slots.

The first runtime slice accepts `void`, signed and unsigned 8/16/32/64-bit
integers, `float`, `double`, and pointers. It rejects invalid signatures and
buffer sizes. Variadics, callbacks, arrays, and aggregates passed by value are
not supported. Prepared functions retain the underlying library safely even if
the `NativeLibrary` wrapper is closed.

The implementation uses `LoadLibraryW`/`GetProcAddress` on Windows and
`dlopen`/`dlsym` on Unix platforms. Loader and invocation failures are copied
into Haxe-owned exceptions; native loader pointers never cross the public API.
