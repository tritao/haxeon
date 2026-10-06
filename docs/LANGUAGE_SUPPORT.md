# Language support

The current subset includes:

- `Int`, `Bool`, `Float`, `String`, nullable values, and dynamic values
- Local variables, functions, methods, recursion, and expression statements
- Classes, interfaces, anonymous structures, enums, and enum abstracts
- Closures with generated environments and shared cells for mutable captures
- Arrays and compiler-owned primitive, string, and reference array operations
- Primitive, reference and value-class valued `Map<String, T>` and `Map<Int, T>` forms
- Arithmetic, bitwise operations, comparisons, string operations, and casts
- `if`/`else`, `switch`, `while`, `do`/`while`, `for`, `break`, and `continue`
- Array iteration and comprehensions
- Exceptions
- Simple `typedef` aliases and generics, including typedefs of anonymous structures that refer to themselves
  (`typedef Tree = {children:Array<Tree>}`), directly, through `Null<>`, in pairs, or per generic instantiation.
  A cycle that does not pass through a structure (`A = B, B = A`, `A = Array<A>`) is still an error.
- Haxe-compatible `Sys` operations through the stable runtime ABI

String addition, equality, `.length`, `indexOf`, and `substring` use the
compiler-owned runtime ABI. Arrays support checked indexing, `.length`, `copy`,
`concat`, `slice`, `indexOf`, `push`, and `pop`. Capacity-aware array growth
preserves object identity so aliases and fields continue to observe the same
array.

HashLink strings use HashLink's standard `String` object layout: zero
terminated UTF-16 data plus its length in code units, so `.length` and
`charCodeAt` take constant time. Haxeon rejects NUL code units when creating a
`String` from a character code or byte buffer, and rejects NUL in compiled
string constants. Use `Bytes` for binary data.

Hosts may register typed HashLink natives with `Compiler.registerNative()`
before the first build. Registrations then freeze so the native-table layout
cannot silently change beneath a live module. `compiler.RuntimeAbi.register()`
installs the stable host surface used by the command-line compiler; Haxeon-owned
realtime operations remain in a separately versioned ABI.

Unsupported ABI combinations produce explicit typed diagnostics instead of
silently falling back to dynamic behavior.

## C header import

A standalone Clang-based importer can generate deterministic, target-specific
raw HXI declarations from a constrained C ABI. It preserves record layouts and
keeps system-header implementation details out of the generated interface. A
strict parser validates types, layouts, symbols, and ABI metadata before use. See
[C header FFI import](C_HEADER_FFI.md) for usage and the supported subset.
The runtime also contains a restricted libffi-based ordinary-C symbol bridge;
the pinned vendored libffi is statically linked into the runtime library, with
no separate libffi runtime dependency. Windows x64 builds compile the pinned
sources directly with CMake and MSVC, without a Cygwin build dependency. This
remains deliberately separate from HashLink's `@:hlNative` convention.

The native-memory model keeps GC-managed Haxe objects separate from fixed-layout
native records. See [native values and memory](NATIVE_MEMORY.md) for the
representation contract and implementation sequence. The frontend recognizes
`@:value @:repr("C")` records, shares ABI layout rules with HXI, and folds
`sizeof`, `alignof`, and `offsetof` queries to constants. HashLink now lowers
typed `RawPtr<T>` memory operations to SSA loads, stores, and offsets, and the
Haxeon `Arena` provides stable bump-allocated native blocks.

## Source-declared HashLink bindings

Target functions can be declared without a Haxe body by combining `extern`
with `@:hlNative`:

```haxe
@:hlNative("std", "sys_time")
extern function nativeTime():Float;
```

The two metadata arguments are the HashLink library and exported symbol.
Bindings participate in normal name and type checking, but emit only a native
table entry. Missing, duplicate, non-string, or malformed bindings are compile
errors. Static methods on `extern class` and static or instance methods on
`extern abstract` use the same form; an instance abstract method passes its
underlying representation as native argument zero.

An extern class or abstract can provide a default library for all its methods.
The method name is used as the native symbol unless the method carries its own
two-argument `@:hlNative` binding:

```haxe
@:hlNative("platform")
extern class Native {
    public static function poll():Int;

    @:hlNative("override", "renamed")
    public static function draw():Void;
}
```

An extern abstract can declare its HashLink storage independently of its source
identity:

```haxe
@:hlType("bytes")
extern abstract Bytes(Dynamic) {}

@:hlType("nativeAbstract")
extern abstract Abstract<T>(Dynamic) {}
```

The supported representations are currently `bytes` and `nativeAbstract`.
Tagged types such as `hl.Abstract<"realtime_module">` use the latter and retain
the quoted tag as part of their ABI identity. These target declarations live
under `stdlib/hl`; unsupported representation names are diagnosed rather than
silently lowered as ordinary objects.

