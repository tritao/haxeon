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

The importer supports C typedefs, annotated opaque handles, anonymous integer enum constants, named enums, fixed-width
enum aliases, structs, fixed-size arrays, pointers, `const`, and non-variadic function declarations.
It maps fixed-width integer typedefs and `size_t`-family types to raw HXI
primitives. Structs carry Clang-computed `@layout` and `@offset` annotations.
Output is sorted so the same header and target produce byte-identical results.
Plain C integer types retain ABI-specific names such as `c_int` and `c_long`;
they are not incorrectly assumed to have a platform-independent width. The
optional library name becomes interface-level `@library` metadata. Use
`--source-label=<repository-relative-path>` for checked-in generated files so
the provenance comment is stable across machines; the input header itself may
still be an absolute path.

NativeKit-style C handles are annotated with `hxi:handle` and must have a
fixed unsigned 32-bit representation. The importer emits them as nominal raw
HXI declarations rather than ordinary structs:

```c
#define NK_HANDLE __attribute__((annotate("hxi:handle")))
#define NK_DECLARE_HANDLE(name) \
    typedef struct name { uint32_t id; } name NK_HANDLE

NK_DECLARE_HANDLE(nkui_resource);
```

```hxi
handle nkui_resource : u32;
```

Handles remain named and type-distinct at the Haxe boundary while retaining a
four-byte value ABI. Their generated Haxe abstracts are copyable, comparable,
hashable, and provide `invalid()`, `isValid()`, and `rawValue()` helpers; the
backing value is not exposed as a writable struct field. A zero value is the
invalid handle convention. This preserves subsystem-specific C types without
collapsing every handle into one universal `nk_handle` parameter type.

An interface may compose declarations from an already registered interface with
repeatable `--depends` options:

```sh
scripts/haxeon-ffi-import \
  --target=x86_64-linux-gnu \
  --library=nativekit_ui \
  --interface=NativeKitUI \
  --depends=NativeKit \
  --exclude-header=/path/to/nativekit/include/nativekit.h \
  --output=generated/nativekit-ui.hxi \
  /path/to/nativekit_ui_import.h
```

This emits `@depends("NativeKit")` on the HXI interface. The dependency must
be passed to the compiler before the dependent interface. Shared declarations
are projected once from the dependency, while functions and types owned by the
dependent interface remain in its generated Haxe module. Dependencies define
ABI visibility and symbol ownership; each interface still retains its own
`@library` for native functions. `--exclude-header` removes declarations whose
source location belongs to a supplied dependency header, leaving references to
those types for the dependency HXI to provide. This keeps the raw artifact and
the composed Haxe module free of duplicate declarations.

When auditing a filtered dependent header, pass the corresponding dependency
artifact with `--dependency-hxi` so the standalone audit can validate external
type references:

```sh
scripts/haxeon-ffi-audit \
  --target=x86_64-linux-gnu \
  --target=x86_64-w64-windows-gnu \
  --depends=NativeKit \
  --dependency-hxi=generated/nativekit.hxi \
  --exclude-header=/path/to/nativekit/include/nativekit.h \
  /path/to/nativekit_ui_import.h
```

Pass one or more generated interfaces to the compiler with repeatable options:

```sh
haxeon-compiler \
  --ffi-interface=generated/nativekit.hxi \
  --ffi-projection=generated/nativekit.hxmap \
  --entry=app.Main \
  sources.manifest
```

Interfaces are parsed and registered before source loading. Their names must be
unique, and the registered set becomes immutable after the first compilation,
matching the existing native-table stability rule for live modules.

Projection manifests are optional Haxe-only JSON files selected with
`--ffi-projection`. They are layered on top of generated HXI and never change
native symbols, layouts, or pointer contracts. A reusable profile can strip a
library prefix and apply C naming transforms, while explicit maps handle
library-specific exceptions:

```json
{
  "interface": "NativeKit",
  "typePrefix": "nk_",
  "enumValuePrefixes": ["NK_"],
  "functionPrefix": "nk_",
  "functionCase": "camel",
  "fieldCase": "camel"
}
```

The projection precedence is explicit declaration mapping, configured naming
rule, then the original HXI name. The `@:cNative` symbol always remains the
native C spelling. This keeps C headers and generated ABI snapshots
language-neutral while allowing each target language to define its own naming
policy.

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

The symbols named by `@owned` and `@length` must also be declared as functions
in the same HXI interface, with matching `@symbol` metadata where the C name
differs from the HXI name. An owned-result release function must use the C
calling convention and have the shape `void release(pointer)`, where the
pointer accepts the result's pointee type or `void *`. A length function must
use the result function's calling convention and argument types, and return an
unsigned target-sized integer (`usize` or `c_size`). These contracts are
validated before projection rather than deferred to runtime symbol lookup.

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
nominal Haxe abstract handles over the same native pointer representation, so
different opaque HXI types cannot be interchanged accidentally. Handles expose
`close()` and `isClosed()`; close is idempotent, and owned values retain the
finalizer fallback. Aliases and `const` qualification preserve the underlying
opaque handle identity. Unannotated pointer results remain rejected at
execution time.

`@length("length_symbol")` turns a pointer to byte-sized data or `void` into a
managed `haxe.io.Bytes` result. The length function receives the same arguments
as the pointer function and returns `size_t`; HXI validation checks that its
declared signature matches. The runtime validates the length against a 256 MiB
safety limit, copies the bytes, and then calls the declared release symbol for
owned results. Borrowed memory is never released. Nullable pointer results
become Haxe `null`; a non-null result contract returning `NULL` is a runtime
boundary error. `@length` is rejected for opaque resource pointers.

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
managed-byte structure cannot retain their destructor safely. A borrowed
`ptr<struct>` field paired with an unsigned count through `@length_field`
accepts storage produced by the element structure's generated `array()` packer.
The owner of that storage must remain reachable through the synchronous native
call; bindings should retain it alongside the containing options structure.
Unannotated pointer fields remain in the ABI model but receive no unsafe
generated accessors. Naturally laid-out structures can also be passed and returned by
value. Their recursive field layout is encoded in the native call descriptor,
including nested structures and fixed arrays; the runtime asks libffi to apply
the platform's aggregate calling convention and verifies the resulting size
and alignment. Packed, over-aligned, or manually gapped layouts remain usable
through pointers but are rejected when projected into a by-value call.

Fixed-size `array<T, N>` fields project indexed getters and setters for integer
and floating-point elements, with bounds checks against `N` before an address
is calculated. Byte arrays additionally provide whole-field managed-byte copy
helpers. Arrays of fixed-layout structures use typed element copies with the
declared structure stride. Array sizes, offsets, alignment, and multiplication
overflow are covered by the same layout validation as other fields.

Function parameters can pair a pointer with an unsigned 32-bit count using
`@in_array("count")`. Fixed-layout structure elements project as `Array<T>` and
are packed into contiguous managed ABI storage for the call. A `ptr<utf8>`
input array projects as `Array<String>` and builds a retained native pointer
table. In both forms the paired count parameter is omitted from the Haxe API
and derived from the array length. Unannotated pointer arrays remain
ABI-visible but receive no managed array projection.

Byte input arrays also receive a generated `<Function>_slice` companion. It
accepts `haxe.io.Bytes`, an offset, and a length, validates the range, and
submits a managed view without copying the selected bytes. This is intended
for coarse command and upload transactions; it does not add per-element FFI
calls.

Use `scripts/haxeon-ffi-audit` to import one public header for multiple targets
and compare its normalized declarations and layouts. The `portable-abi64`
profile additionally rejects ABI-dependent public scalars such as `long`,
`size_t`, `wchar_t`, and C `bool`. Audits run Clang in freestanding mode, so
headers limited to the portable C ABI can be checked for Apple and Windows
targets without installing their platform SDKs:

```bash
scripts/haxeon-ffi-audit header.h \
  --target=x86_64-linux-gnu \
  --target=x86_64-w64-windows-gnu \
  --target=arm64-apple-darwin \
  --profile=portable-abi64
```

`--format=json` emits the same result as a machine-readable CI report. Any
import failure, portability violation, or normalized ABI difference exits
nonzero. After a successful comparison, `--output=library-abi64.hxi` writes a
single canonical interface using `@target("portable-abi64")`; failed audits do
not touch the output file.

HXI `@library` values without a path separator or filename extension are
logical library names. The runtime maps `nativekit` to `libnativekit.so` on
Linux, `libnativekit.dylib` on macOS, and `nativekit.dll` on Windows. Values
containing a path separator or dot are treated as explicit paths or filenames
and passed to the platform loader unchanged.

Function parameters may be marked `@out` or `@inout` after a pointer type. The
generated module keeps the pointer-shaped C entry point private and exposes a
typed wrapper. Scalar pointees use correctly sized temporary native storage;
fixed-layout structure pointees use their generated structure abstract. An
`@out` parameter is omitted from the Haxe arguments, while `@inout` accepts the
initial pointee value. A non-void C result is returned as the `status` field of
a generated `<Function>OutResult` class alongside fields named after each
directed parameter. A void function with one directed parameter returns that
value directly. Structure `@inout` values are updated in place and also appear
in the result. Output parameters cannot be nullable. Callback directions,
pointer-to-pointer outputs, and ownership transfer through output slots remain
unsupported until they have explicit contracts.

A conventional two-call byte buffer uses an explicit paired contract:

```hxi
extern fn read(
    data: nullable<ptr<u8>> @out_buffer("size"),
    size: ptr<u32> @inout
) -> i32;
```

The wrapper first calls the function with a null buffer and zero capacity,
allocates the returned size, then calls it again with managed storage. The final
`size` is validated against the allocation and trims the result when fewer bytes
were written. Sizes are limited to 256 MiB. The size parameter must be
`ptr<u32> @inout`; it and the buffer are hidden from the public Haxe signature.
The first call's result is intentionally ignored, since many C APIs report
insufficient capacity during a successful size query. Other input parameters
are passed identically to both calls, so such functions must make their query
invocation side-effect safe. Multiple output buffers and mixtures with other
output parameters are rejected for now.

Named HXI `enum` and `flags` declarations use an explicit `i8`/`u8`, `i16`/`u16`,
or `i32`/`u32` representation. Their values accept decimal and hexadecimal
integer literals, unary minus, parentheses, `<<`, `>>`, and bitwise `|`.
Validation catches duplicate names and values, invalid shifts, and values outside
representable widths. Both forms project as nominal Haxe enum abstracts while
native calls and structure fields retain the declared integer ABI. Clang-imported
named C enums currently use `c_int` unless the header specifies a fixed underlying
type; `flags` remains an explicit HXI authoring distinction rather than a heuristic.

Headers that must keep a fixed-width typedef ABI can opt into the same nominal
projection without changing the C type. Place an `hxi:enum:<typedef>` annotation
on the anonymous enum, for example:

```c
#define HXI_ENUM(name) __attribute__((annotate("hxi:enum:" #name)))
typedef uint32_t sample_mode;
enum HXI_ENUM(sample_mode) { SAMPLE_MODE_DEFAULT = 0, SAMPLE_MODE_ALTERNATE };
```

The importer emits `enum sample_mode : u32` and omits the duplicate scalar alias.
The typedef remains the ABI source of truth, while enum values retain their
documentation and implicit C enumerator values are materialized in HXI. The
semantic Haxe projection exposes those values through the typed enum abstract.

Semantic projections name snake-case enums in concise PascalCase, such as
`Result.Ok` and `EventKind.WindowClose`. The C/HXI spellings remain unchanged
at the native interface boundary.

C function-pointer typedefs import as HXI `callback` declarations. Scalar and
by-value structure arguments and results use the same recursive ABI descriptors
as ordinary calls, with `void` also accepted as a result.
Projection generates a typed Haxe function alias and a distinct managed callback
handle. Constructing the handle allocates a libffi closure and roots the Haxe
function; `close()` releases both resources and is idempotent. If C retains the
function pointer, callers must retain this handle until they have unregistered
the callback, then close it. Invocations are accepted only on the thread where
the handle was created; a call from another thread does not enter Haxe and
returns a zero value. Pointer arguments are borrowed, scoped wrappers: opaque
and `void *` values use non-owning pointer handles, while pointers to fixed-layout
structures use typed byte views of exactly the declared structure size, while
by-value structure arguments use equivalent callback-scoped views. Aggregate
results are copied into libffi's return storage before scoped arguments expire,
so a callback may return one of its by-value arguments. Nullable
pointers map to Haxe `null`. Every non-null wrapper is invalidated immediately
after the callback returns, including exceptional returns, so retaining one does
not extend the native address lifetime. A null address passed for a non-null HXI
parameter causes the callback to return zero without entering Haxe. Pointer
callback results, variadic callbacks, and callbacks with more than sixteen
arguments are rejected for now.

Callback failures never unwind through the C stack. Each callback handle keeps
the first unread failure in a small synchronized record and returns the ABI zero
value to C. Generated `errorKind()` reports `HxiCallbackError.Exception`,
`WrongThread`, `PointerContract`, or `AggregateContract`; `takeError()` returns
the diagnostic as managed UTF-8 bytes and atomically clears both the diagnostic and kind. This
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

The runtime accepts `void`, signed and unsigned 8/16/32/64-bit integers,
`float`, `double`, pointers, and recursively described C structures. Aggregate
arguments use fixed-size managed buffers and aggregate results return new owned
typed buffers. Invalid signatures, layouts, and buffer sizes are rejected.
Variadic calls remain unsupported. Prepared functions retain the underlying
library safely even if the `NativeLibrary` wrapper is closed.

## UTF-8 strings

HXI uses `utf8` and `nullable<utf8>` for NUL-terminated UTF-8 text. This is an
explicit contract and is not inferred from arbitrary `char *` declarations.
Arguments project as `String`/`Null<String>` and are transcoded for the duration
of the call. Results require `@borrowed` or `@owned("release_symbol")`; owned
storage is released after conversion, including when validation fails. Results
are validated as Unicode UTF-8 and bounded to 16 MiB before conversion.

Callbacks accept the same string types. Incoming text is validated before Haxe
is entered. Returned strings are retained by the callback handle until its next
invocation or closure, and null or invalid results against a non-null contract
are reported as `HxiCallbackError.StringContract` while returning `NULL` to C.

The header importer recognizes deliberately named `hxi_utf8` and
`hxi_nullable_utf8` typedef uses. It leaves ordinary character pointers alone,
because neither encoding nor ownership can be inferred safely from C syntax.
Result ownership must still be reviewed and added to the generated HXI.

HXI maps 64-bit integer ABI values to the compiler's `haxe.Int64` primitive and
the `I64` SSA/HashLink representation. Consequently `c_long` projects to
`haxe.Int64` on LP64 targets while remaining `Int` on Windows LLP64 targets;
`isize` and `usize` likewise follow the selected target's pointer width.

The implementation uses `LoadLibraryW`/`GetProcAddress` on Windows and
`dlopen`/`dlsym` on Unix platforms. Loader and invocation failures are copied
into Haxe-owned exceptions; native loader pointers never cross the public API.
