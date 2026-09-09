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

The importer supports C typedefs, anonymous integer enum constants, named enums, structs,
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

Raw HXI is the generated ABI interchange layer. Imported headers leave pointer
ownership unspecified for later review. Handwritten or enriched HXI can mark
pointer results with `@borrowed` or `@owned("release_symbol")`, and byte-like
pointer results with `@length("length_symbol")`. Haxeon parses these policies
alongside opaque types and `@symbol`/`@leaf` function metadata.

Bridgeable functions are also projected into a generated Haxe module named
after the HXI interface. The initial projection accepts 8/16/32-bit integers,
64-bit integers, `float`, `double`, pointers, and `void` results. Unsupported
declarations such as by-value aggregates remain available in the raw ABI model
but are omitted from the source module until their Haxe representation is
defined.

Each projected function carries private `@:cNative(library, symbol, signature)`
metadata. The typer preserves that descriptor and emits a dedicated
`CNativeCall` instruction, keeping ordinary C calls separate from HashLink's
native calling convention throughout typed AST, CFG, SSA IR, verification, and
serialization. The HashLink backend lowers scalar calls through the ordinary-C
runtime bridge. Libraries and prepared libffi functions are cached by library,
symbol, and signature, so repeated calls do not repeat loading or lookup.
Integer—including native 64-bit and target-sized integer—and floating-point
arguments and results, `void` results, and managed
byte-buffer pointer arguments—including explicit `nullable<ptr<T>>` values—are
executable. Calls accept up to sixteen arguments. Pointers to opaque types use
opaque handles with explicit, idempotent close operations and finalizer
fallback for owned values. Unannotated pointer results remain rejected at
execution time.

`@length("length_symbol")` turns a pointer to byte-sized data or `void` into a
managed `haxe.io.Bytes` result. The length function receives the same arguments
as the pointer function and returns `size_t`. The runtime validates the length
against a 256 MiB safety limit, copies the bytes, and then calls the release
symbol for owned results. Borrowed memory is never released. Nullable pointer
results become Haxe `null`; a non-null result contract returning `NULL` is a
runtime boundary error. `@length` is rejected for opaque resource pointers.

HXI structures with explicit `@layout(size, align)` and field `@offset(...)`
metadata project to typed Haxe abstracts backed by managed bytes. Constructing
the abstract zero-initializes exactly the declared size. Generated `get_field`
and `set_field` methods support native-endian integer and floating-point scalar
fields. Nested fixed-layout structures use typed copy getters and setters, and
`ptr<struct>` parameters pass the managed backing storage to C. Validation
rejects misaligned, overlapping, and out-of-bounds fields before projection.
Borrowed pointers to opaque types can be marked with field-level `@borrowed`;
their generated accessors read and write `NativePointer` handles and preserve
`nullable<...>` behavior. The source handle must remain live for as long as C
may read the structure field. Owned pointer fields are rejected because a
managed-byte structure cannot retain their destructor safely. `@length_field`
is likewise reserved until structures can retain input buffers. Unannotated
pointer fields remain in the ABI model but receive no unsafe generated
accessors. By-value structures are not executable yet.

Fixed-size `array<T, N>` fields project indexed getters and setters for integer
and floating-point elements, with bounds checks against `N` before an address
is calculated. Byte arrays additionally provide whole-field managed-byte copy
helpers. Arrays of fixed-layout structures use typed element copies with the
declared structure stride. Array sizes, offsets, alignment, and multiplication
overflow are covered by the same layout validation as other fields. Pointer
arrays remain ABI-visible but unprojected pending an explicit lifetime model.

Named HXI `enum` and `flags` declarations use an explicit `i8`/`u8`, `i16`/`u16`,
or `i32`/`u32` representation. Their values accept decimal and hexadecimal
integer literals, unary minus, parentheses, `<<`, `>>`, and bitwise `|`.
Validation catches duplicate names and values, invalid shifts, and values outside
representable widths. Both forms project as nominal Haxe enum abstracts while
native calls and structure fields retain the declared integer ABI. Clang-imported
named C enums currently use `c_int` unless the header specifies a fixed underlying
type; `flags` remains an explicit HXI authoring distinction rather than a heuristic.

C function-pointer typedefs import as HXI `callback` declarations. Scalar
callback arguments and results use the same integer and floating-point ABI
classification as ordinary calls, with `void` also accepted as a result.
Projection generates a typed Haxe function alias and a distinct managed callback
handle. Constructing the handle allocates a libffi closure and roots the Haxe
function; `close()` releases both resources and is idempotent. If C retains the
function pointer, callers must retain this handle until they have unregistered
the callback, then close it. Invocations are accepted only on the thread where
the handle was created; a call from another thread does not enter Haxe and
returns a zero value. Pointer arguments are borrowed, scoped wrappers: opaque
and `void *` values use non-owning pointer handles, while pointers to fixed-layout
structures use typed byte views of exactly the declared structure size. Nullable
pointers map to Haxe `null`. Every non-null wrapper is invalidated immediately
after the callback returns, including exceptional returns, so retaining one does
not extend the native address lifetime. A null address passed for a non-null HXI
parameter causes the callback to return zero without entering Haxe. Pointer
callback results, variadic callbacks, and callbacks with more than sixteen
arguments are rejected for now.

Callback failures never unwind through the C stack. Each callback handle keeps
the first unread failure in a small synchronized record and returns the ABI zero
value to C. Generated `errorKind()` reports `HxiCallbackError.Exception`,
`WrongThread`, or `PointerContract`; `takeError()` returns the diagnostic as
managed UTF-8 bytes and atomically clears both the diagnostic and kind. This
makes failures pollable from an application event loop and attributes them to
the callback that failed. A later successful invocation does not erase an
unread failure.

Callback handles can be made nullable at an HXI use site with
`nullable<CallbackName>`. They project as `Null<CallbackNameCallback>` and a
Haxe `null` crosses the ABI as a null function pointer, matching conventional
registration APIs that unregister with `set_handler(NULL)`. Clang `_Nullable`
function-pointer parameters import in this form, while `_Nonnull` retains the
plain callback type. A closed non-null handle is rejected before entering C.
Applications must unregister a callback and only then call `close()`; closing a
function pointer that native code may still invoke remains a caller lifetime
error.

Functions and callbacks accept `@callconv("cdecl")`, `@callconv("stdcall")`, or
`@callconv("system")`; omitted metadata means `cdecl`. The convention is encoded
in the executable ABI signature, so call-cache entries with different
conventions cannot alias. `system` selects `stdcall` on 32-bit Windows and the
platform default elsewhere. Explicit `stdcall` is accepted only for Windows
targets, maps to libffi's stdcall ABI on 32-bit Windows, and uses the unified
default ABI on 64-bit Windows. Clang `__stdcall` declarations and function-pointer
typedefs retain this metadata during import. Associated byte-length helper calls
use the same convention as their pointer-returning function.

## Native call runtime

The runtime has a separate ordinary-C call bridge built on libffi. This is not
the HashLink `@:hlNative` ABI. `runtime.NativeLibrary` explicitly opens and
closes a dynamic library, resolves a `runtime.NativeFunction` with a fixed
signature, and invokes it through native-endian eight-byte value slots.

The first runtime slice accepts `void`, signed and unsigned 8/16/32/64-bit
integers, `float`, `double`, and pointers. It rejects invalid signatures and
buffer sizes. Variadics, arrays, and aggregates passed by value are
not supported. Prepared functions retain the underlying library safely even if
the `NativeLibrary` wrapper is closed.

HXI maps 64-bit integer ABI values to the compiler's `haxe.Int64` primitive and
the `I64` SSA/HashLink representation. Consequently `c_long` projects to
`haxe.Int64` on LP64 targets while remaining `Int` on Windows LLP64 targets;
`isize` and `usize` likewise follow the selected target's pointer width.

The implementation uses `LoadLibraryW`/`GetProcAddress` on Windows and
`dlopen`/`dlsym` on Unix platforms. Loader and invocation failures are copied
into Haxe-owned exceptions; native loader pointers never cross the public API.
