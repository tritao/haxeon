# C header FFI import

## C++ direct-call import (CXX_ABI_V1)

The importer also has an intentionally small C++ path. Select it explicitly;
the generated artifact is still ordinary HXI, so the existing native ABI
classifier and runtime handle the call:

```sh
scripts/haxeon-ffi-import \
  --language=c++ \
  --std=c++20 \
  --target=x86_64-linux-gnu \
  --include=/path/to/library/include \
  --output=generated/library.hxi \
  /path/to/library/include/library.hpp
```

Project recipes may make the dispatch contract explicit with
`"profile": "direct"`. Direct is the strict no-adapter profile: it forbids
generated C++ thunks and virtual dispatch, so every imported call must use a
Clang-selected mangled symbol with the ordinary HXI ABI. It still permits
ABI-safe `noexcept` constructors, destructors, and explicit ownership release
functions. The default profile preserves the individual legacy opt-in flags;
`"profile": "virtual"` is a named opt-in for the existing Itanium vtable
dispatch path. The standalone equivalent is `--cxx-profile=direct` or
`--cxx-profile=virtual`.

The direct profile imports namespaces, aliases, enum classes, opaque
records, free functions, static methods, and public non-virtual `noexcept`
methods. A member method is lowered to an HXI function with a synthetic
`__this` pointer, while the `@symbol` value is exactly Clang's mangled name.
References are represented as non-null pointer ABI values. Virtual methods and
inheritance require the separate opt-in `--cxx-profile=virtual` profile; the
legacy `--cxx-virtual` flag remains accepted for compatibility. That profile
currently supports only Clang's Itanium ABI on 64-bit Linux/macOS and a single
non-virtual base. The generated Haxe method reads the object's vtable and calls
the selected function pointer, preserving dynamic dispatch. MSVC virtual
dispatch is diagnosed until its ABI metadata path is implemented. Rvalue
references, throwing calls, and non-trivial class values
produce `CXX` diagnostics instead of an unsafe binding. Trivial record values
are opt-in through `--cxx-trivial-values`. Constructors and destructors are
also opt-in through `--cxx-lifetimes` and must be public, `noexcept`, and
defined on a complete record with an explicit destructor.

Throwing scalar and pointer functions or methods can be bound through a
generated C++ catch thunk:

```sh
scripts/haxeon-ffi-import \
  --language=c++ \
  --target=x86_64-linux-gnu \
  --library=/path/to/library-with-thunks.so \
  --cxx-thunks=generated/library-thunks.cpp \
  --haxe-output-dir=generated/library-cxx \
  --output=generated/library.hxi \
  /path/to/library/include/library.hpp
```

Compile the generated `.cpp` into the library named by `--library`. Each
thunk is an `extern "C"` function with the same ABI-shaped arguments and
result as its HXI declaration. It catches `std::exception` and unknown
exceptions, stores a bounded thread-local diagnostic, and returns the
zero/null fallback for the declared result. Generated Haxe projections read
that diagnostic immediately after the call and throw a Haxe exception. This
mode currently excludes throwing constructors/destructors, references as
results, and non-trivial/STL conversions other than the explicitly supported
`std::string_view` and read-only byte `std::span` input adapters. A
`std::string_view` parameter is lowered to `const char*` plus a target-sized
byte length inside the generated thunk; the Haxe projection accepts a `String`
and computes its UTF-8 byte length. A `std::span<const std::byte>` or
`std::span<const uint8_t>` parameter is lowered to `const byte*` plus a
target-sized element count; the Haxe projection accepts `haxe.io.Bytes`. Both
views are borrowed for the duration of the synchronous call, so the C++ API
must not retain them. Embedded NUL bytes are not supported by the current
UTF-8 bridge. Mutable, fixed-extent, non-byte, result, pointer, and reference
span positions are unsupported. Unsupported string-view positions report
`CXX017`; unsupported byte-span positions report `CXX018`. Without
`--cxx-thunks`, throwing declarations continue to report `CXX003`, and view
adapters report their corresponding diagnostic.

With `--haxe-output-dir=<directory>`, the C++ importer also emits one Haxe
class module per imported record. The generated class stores the raw opaque
pointer, exposes `fromNative()` and `nativeHandle()`, and projects supported
instance and static methods while retaining the HXI module as the ABI source:

```sh
scripts/haxeon-ffi-import \
  --language=c++ \
  --target=x86_64-linux-gnu \
  --library=nativekit \
  --interface=NativeKit \
  --haxe-output-dir=generated/nativekit-cxx \
  --output=generated/library.hxi \
  /path/to/library/include/library.hpp
```

Add the projection directory as a source root when compiling the application,
alongside the generated HXI interface:

```sh
haxeon-compiler \
  --root=generated/nativekit-cxx \
  --ffi-interface=generated/library.hxi \
  --entry=app.Main \
  sources.manifest
```

The generated `DisplayList.hx`-style modules are intentionally thin. Without
`--cxx-lifetimes`, they expose borrowed `fromNative()` wrappers and do not
allocate or destroy C++ objects; callers supply a native pointer obtained from
an API with an explicit ownership contract. With lifetime support enabled,
each constructor becomes `create()` (or a numbered overload), which allocates
storage through the runtime and invokes the Clang-selected constructor symbol;
`close()` invokes the destructor and then releases that storage. Borrowed
wrappers cannot be closed. Overloaded methods receive stable numeric suffixes
until a richer Haxe overload policy is added.

Factory ownership is explicit and configured separately from C++ syntax. Map a
free function returning `T*` to a free function accepting `T*` and returning
`void` with `cxxOwnership` in a project recipe:

    {
      "cxxOwnership": {
        "nkui::create_display_list": "nkui::release_display_list"
      },
      "cxxThunks": true,
      "projection": true
    }

The equivalent standalone option is repeatable:

    --cxx-owned=nkui::create_display_list=nkui::release_display_list

The importer lowers the factory result to HXI `@owned("release_symbol")`
metadata and emits `OwnedDisplayList.hx` plus an owned factory projection. The
owner exposes `borrow()`, `nativeHandle()`, `isClosed()`, and idempotent
`close()`. The release function must be explicit; C++ names and method names
are never guessed. With `cxxThunks`, both the factory and release call use
generated C-ABI entry points, which also keeps hidden C++ symbols and exception
boundaries out of the Haxe runtime. `std::unique_ptr<T>` remains unsupported as
a direct ABI value; adapt it through an explicit factory/release pair instead.

The MSVC x64 profile is covered as a cross-target import (`x86_64-pc-windows-msvc`)
even on non-Windows hosts. It uses Clang's MSVC mangled names and LLP64 layout
rules; executing the resulting library still requires a Windows build and
runtime.

Large C++ headers can be narrowed with repeatable `--cxx-select=<qualified-name>`
options. Select a record to retain all of its supported members, or select
individual methods, free functions, enums, and aliases. Selecting a method
implicitly retains its owning record. Named records, enums, and aliases used by
selected signatures are retained transitively, including alias chains; a
dependency hidden by the import roots or excluded headers reports CXX019
instead of being silently dropped. This is useful for headers that expose a
small supported facade alongside internal constructors, virtual classes, or
template-heavy declarations.

FFI imports can be attached to a Haxeon package instead of being generated by
an ad hoc shell command. Add recipe paths to the package manifest:

    {
      "version": 1,
      "package": { "name": "nativekit-bindings" },
      "ffi": {
        "imports": ["ffi/nativekit-display-list.ffi.json"]
      }
    }

The recipe contains the Clang and declaration-selection details:

    {
      "version": 1,
      "name": "nativekit-display-list",
      "language": "c++",
      "header": "nativekit/.../display_list.h",
      "std": "c++20",
      "includes": ["nativekit/.../ui/src"],
      "library": "nativekit_ui",
      "interface": "NativeKitDisplayList",
      "select": [
        "nkui::DisplayList::reset",
        "nkui::DisplayList::size"
      ],
      "projection": true
    }

Paths in an FFI recipe are relative to the recipe file. During a project build,
the package target supplies the Clang target triple. Haxeon generates HXI and
optional C++ object projections below the target build directory, fingerprints
the recipe and its header inputs, and makes Haxe compilation depend on the
generated interface. Standalone generation also accepts
haxeon-ffi-import --manifest=<file>.

For project-owned C++ implementations, `"cxxThunks": true` makes the build
generate the thunk `.cpp`, compile it, and link a separate ordinary shared
library for the HXI calls. With `native.sources`, the package sources and thunk
objects are linked together. With `native.cmake`, the thunk library links
against the CMake target output, so the package's existing `CMakeLists.txt`
needs no Haxeon-specific hook. The generated FFI library is distinct from the
package's `.hdll` because HXI `@:cNative` calls use the platform shared-library
ABI.

On Windows, the CMake provider requests configuration-specific native output
directories and links the target's import archive (`.lib` for MSVC or `.dll.a`
for MinGW) into the generated thunk library. The CMake target should therefore
produce the package's declared `<package>.hdll` output and its matching import
archive in the same native output directory.

NativeKit integration currently uses its stable public C ABI through the C
importer. Its `nkui::DisplayList` implementation is an internal C++ class:
its methods are not `noexcept`, and the shared UI library hides its C++ symbols.
It therefore must not be presented as a direct call into the shipped shared
library. An opt-in audit checks the real header and NativeKit compilation
database and asserts the expected actionable diagnostics. It also builds the
actual `display_list.cpp` beside a test-only factory and Haxeon's generated
thunks, then executes `reset()` and `size()` through the generated projection.
That positive path verifies the importer and thunk ABI against NativeKit's real
C++ implementation without changing NativeKit's production exports. It is kept
out of the default test suite because NativeKit is an external, optional
dependency:

```sh
NATIVEKIT_ROOT=/path/to/nativekit \
NATIVEKIT_BUILD_DIR=/path/to/nativekit/build-ui-integrated \
tests/integration/test-nativekit-cxx-profile.sh
```

The existing C API remains the correct production binding for the current
NativeKit build. A future NativeKit release can promote the source-level test
to a shared-library test once it exports an intentional C++ surface.

Use repeatable `--define=<name[=value]>` options for explicit preprocessor
definitions. `--compile-commands=<path>` accepts a Clang
`compile_commands.json` database and contributes the selected command's
include/define/toolchain flags while the requested target and language mode
remain authoritative.

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
#define NK_HANDLE_DESTROY(symbol) __attribute__((annotate("hxi:handle_destroy")))
#define NK_OWNED __attribute__((annotate("hxi:owned")))
#define NK_DECLARE_HANDLE(name) \
    typedef struct name { uint32_t id; } name NK_HANDLE

typedef uint32_t nkui_resource NK_HANDLE NK_HANDLE_DESTROY(nkui_resource_destroy);
nkui_resource nkui_resource_create(void) NK_OWNED;
void nkui_resource_destroy(nkui_resource resource);
```

```hxi
handle nkui_resource : u32 @destroy("nkui_resource_destroy");
extern fn nkui_resource_create() -> nkui_resource @owned;
```

Handles remain named and type-distinct at the Haxe boundary while retaining a
four-byte value ABI. Their generated Haxe abstracts are copyable, comparable,
hashable, and provide `invalid()`, `isValid()`, and `rawValue()` helpers; the
backing value is not exposed as a writable struct field. A zero value is the
invalid handle convention. A handle's optional `@destroy` names an explicit
by-value release function that accepts that handle and returns `void` or an
integer/enum status; the importer never infers it from a function name. A
function result or `@out` slot only becomes an owned Haxe value when it also
has an explicit bare `@owned` annotation. Those projections return a
generated closeable owner with idempotent `close()`, `isClosed()`, `borrow()`,
and deliberate `rawValue()` access. Unannotated results and output slots remain
non-owning handles. This preserves subsystem-specific C types without
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

A projection can also define a conventional checked-result surface without
changing the raw result-returning ABI function:

```json
{
  "interface": "NativeKit",
  "resultPolicies": {
    "nk_result": {
      "successValue": "NK_OK",
      "diagnosticFunction": "nk_last_error",
      "errorType": "NativeKitError",
      "checkedSuffix": "_checked"
    }
  }
}
```

For an HXI function returning `nk_result`, the generated module keeps
`nk_window_show(...) : Result` and adds `nk_window_show_checked(...) : Void`.
The checked helper throws the configured Haxe error type on failure. Its
constructor accepts `(result, operation, diagnostic)`. For functions with
annotated output values, the checked helper returns those values after success;
the raw status remains available through the original projected function.
`resultPolicies` belongs to `.hxmap` because success conventions, diagnostics,
and exception classes are language-facing policy, not ABI facts.

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
pointer results with `@length("length_symbol")`. Value handles can name their
release function on the handle declaration and use bare `@owned` on a returned
handle or `@out` handle slot. Haxeon parses these policies alongside opaque
types and `@symbol`/`@leaf` function metadata.

Functions named by pointer `@owned("release_symbol")`, handle `@destroy`, and
`@length("length_symbol")` must be declared in the same HXI interface, with
matching `@symbol` metadata where the C name differs from the HXI name. An
owned opaque-pointer release function must use the C calling convention and
have the shape `void release(pointer)`, where the pointer accepts the result's
pointee type or `void *`. A value-handle destroy function must use the C
calling convention and accept the handle by value. A length function must
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
different opaque HXI types cannot be interchanged accidentally. Borrowed opaque
handles expose `isClosed()`. An `@owned` opaque result is instead returned as
`Owned<Type>`, which exposes idempotent `close()`, `isClosed()`, and an explicit
`borrow()` view for APIs expecting `<Type>`; owned values retain the finalizer fallback.
Borrowed views are not statically tied to their owner's lifetime and become
invalid after that owner is closed. Aliases and `const` qualification preserve
the underlying opaque handle identity. Unannotated pointer results remain
rejected at execution time.

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
projects as an `Array<T>` setter. It packs contiguous element storage, writes the
paired count, and retains the packed storage in the containing generated struct.
Borrowed byte buffers and UTF-8 pointer tables use the same explicit relationship
to retain their packed storage. Nested structure copies and generated struct arrays
carry these retained references forward. Native pointers derived from the structure
remain call-scoped; unannotated pointer fields receive no inferred retention.
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
in the result. The outer pointer that represents an output slot cannot be
nullable. Callback directions and `@inout` pointer-to-pointer slots remain
unsupported. Opaque pointer and nominal value-handle output slots are
supported when their ownership is explicit:

```hxi
opaque context;
extern fn create_context(
    result: ptr<nullable<ptr<context>>> @out @owned("context_release")
) -> void;

handle window : u32 @destroy("window_destroy");
extern fn create_window(result: ptr<window> @out @owned) -> void;
```

For an opaque `T *` written through a `T **` slot, use `@borrowed` or
`@owned("release_symbol")` on the `@out` parameter. The inner
`nullable<ptr<T>>` controls whether the slot may contain `NULL`; for a `void`
function with one opaque-pointer output, the Haxe wrapper returns `Null<T>` or
the nullable generated owned-pointer type, respectively. Owned pointer slot
values are adopted into the same closeable type as owned pointer results. An
owned value-handle slot returns its generated owned value-handle type. Scalar and
fixed-structure outputs keep their existing contracts; unannotated or
non-opaque pointer slots remain rejected.

The `wasm-gc` target bridges scalar slots and pointer-free fixed-layout
structure slots through temporary linear-memory storage. The declared size
and alignment are carried in IR and checked during lowering; a structure value
with the wrong backing length traps before entering the native import. This
bridge supports input, output, and in/out structure pointers, plus structure
arguments and results declared by value. At the Wasm import boundary, a
structure argument is passed as an `i32` pointer to aligned scratch bytes, and
a structure result is an `i32` pointer supplied by the host adapter; the
adapter must use the HXI structure's size, alignment, and field layout. The GC
backend copies these bytes to or from GC-managed storage. Borrowed opaque
pointers can be returned, passed to imports, and read from output slots as
32-bit native handles. Owned opaque pointers are supported for direct results
and output slots when the matching release import is declared; their generated
`close()` method calls that import at most once, and `isClosed()` reports the
state. Closing is explicit: Wasm GC does not run the Haxe release import when
an owner becomes unreachable. HXI interfaces with a 64-bit pointer ABI are
rejected by this bridge, and fixed-layout structures containing pointer fields
remain unsupported.

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

C and C++ free-function-pointer typedefs import as HXI `callback` declarations.
For C++, `using Callback = result (*)(args...)` and equivalent typedefs are
supported for input callback parameters. The importer preserves the named
callback type, lowers the native argument as the function-pointer ABI value,
and invokes the exact Clang-selected C++ symbol directly; no C++ adapter thunk
is generated. C++ callback results, member-function pointers, overloaded
function-pointer types, and `std::function` remain unsupported.

Scalar and
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
