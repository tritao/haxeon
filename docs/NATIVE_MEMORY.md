# Native values and memory

Haxeon keeps GC-managed objects and native memory as separate representations.
Ordinary Haxe classes are GC-managed references. Their object headers, identity,
and lifetime belong to the HashLink runtime.

An ordinary `@:value` class remains a HashLink value structure. It does not
promise a C layout. Adding `@:repr("C")` to an `@:value` class instead declares
a distinct native record:

```haxe
@:value
@:repr("C")
class Vec2 {
	public var x:Float32;
	public var y:Float32;
}
```

Native records have no HashLink object header, GC metadata, object identity,
inheritance, or virtual dispatch. Their size, alignment, and field offsets are
target-specific C ABI facts. Haxe-declared records use `HxiAbi`, the same
classifier used for HXI-imported C records; HXI's Clang-reported record sizes
and offsets remain authoritative for imported declarations.

Native records can be used only through pointers. They cannot be constructed,
passed, returned, or stored by value as Haxe runtime values. Supported record
fields are fixed-width scalars, target-defined C scalar aliases, `Int`, `Float`,
`Bool`, pointers, and nested native records. Strings, arrays, ordinary classes,
closures, `Dynamic`, and all other GC-managed references are rejected. A native
union can be declared with `@:union`; its fields overlap at offset zero and its
size and alignment are the target-specific maximum of those fields. Inline C
arrays use `@:array(N)` on the element field and occupy `N` consecutive
elements in the record.

Imported HXI records add `@:layout(size, alignment)` and `@:offset(bytes)`
metadata to this same source form. The compiler checks those Clang facts
against its ABI-derived layout, including explicit C padding, before exposing
the record through `RawPtr<T>`.

```haxe
@:value
@:repr("C")
@:union
class Payload {
	public var integer:Int64;
	public var pointer:RawPtr<Vec2>;
}
```

## Raw pointers

`runtime.memory.RawPtr<T>` is a non-owning pointer to unmanaged storage. It has
the HashLink `Bytes` pointer ABI representation. The initial API is:

```haxe
RawPtr.nullPtr()       // requires a RawPtr<T> result context
p.isNull()
p.load()               // scalar or pointer pointee only
p.store(value)         // scalar or pointer pointee only
p.offset(elements)
p.byteOffset(bytes)
p.castTo()             // requires a RawPtr<U> result context
p.ref.field            // native-record field load
p.ref.field = value    // native-record field store
```

Pointer offsets and memory accesses are explicit SSA instructions. HL lowering
uses HashLink's existing untyped memory opcodes; byte offsets use its existing
`std.bytes_offset` operation. `p.ref` is a compiler-only marker for a
`RawPtr<@:repr("C")>` pointee; field access lowers to the same constant byte
offset and `RawPtr` memory load/store operations as the explicit form. It does
not introduce a second native memory model. For a pointer-valued field, the
field load or store uses the pointer-sized native representation.
For a fixed array field, `p.ref.values` produces a `RawPtr<T>` to its first
element; use `offset(index)` to access an element.

Raw pointers do not own their targets, keep them alive, or prevent invalidation.
The compiler does not infer ownership, borrowing, or lifetimes. A pointer becomes
invalid when its owning arena is reset or disposed.

## Native function-pointer slots

HXI callback declarations used by generated native records project to
`runtime.memory.NativeFunctionPointer<S>`. `S` is a phantom Haxe function
signature, so two callback slots with different signatures are not silently
interchanged in source code. The value has the same non-owning, pointer-sized
ABI representation as `RawPtr<UInt8>` and uses the same layout, null, and SSA
memory rules. It exposes only `isNull()` and `raw()`; it does not own a closure,
root a Haxe function, or invoke through the address. Use the separate managed
callback-handle projection for callbacks that enter Haxe, and keep the native
function-pointer slot for runtime tables and callback storage until an explicit
calling-convention-aware invocation layer is added.

## Layout queries

These operations resolve against the selected target ABI and become integer
constants during typing:

```haxe
sizeof<Vec2>();
alignof<Vec2>();
offsetof<Vec2>("y");
```

The CLI uses a registered HXI target when present. Otherwise `wasm32` and
`wasmgc` select the 32-bit profile, while `wasm64` and `hl` select the 64-bit
profile. `native-abi-target` selects an explicit target triple, such as
`x86_64-pc-windows-msvc`. Direct library typing defaults to the portable 64-bit
profile unless the caller supplies a target.

## Arena

`runtime.memory.Arena` uses aligned bump allocation over non-moving blocks:

```haxe
final arena = new Arena();
var one:RawPtr<Vec2> = arena.alloc();
var many:RawPtr<Vec2> = arena.alloc(32);
arena.reset();
arena.dispose();
```

The pointee type is inferred from the expected `RawPtr<T>` type. `reset()` makes
all existing pointers invalid and allows the blocks to be reused. `dispose()`
releases every block and is safe to call repeatedly. Allocation count must be
positive. Native records may request a larger power-of-two alignment with
`@:align(N)`; blocks whose base alignment is too small are not reused for
those records. There is no individual `free` operation.

Haxeon performs layout-based alignment, bump advancement, block growth, and
reset. The native runtime acquires aligned raw backing blocks and releases
them. This implementation currently targets
HashLink; it does not change the HashLink fork. HXI-imported records can be
projected as fresh native records or bound to an existing canonical Haxe
native declaration with `HxiNativeRecordEmitter`. The binding form emits a
type alias, so the imported declaration and the canonical declaration share
one `RawPtr<T>` representation instead of creating duplicate record types.

HashLink metadata tables use `runtime.hashlink.HlTypeTable`. Type records are
reserved in a separate contiguous slab owned by `HlTypeArena`, matching
HashLink's `hl_code.types` representation; nested descriptors and derived
records remain in the ordinary arena. Adding a type allocates only a new
pointer slot, while each `hl_type` record remains at a stable address. When the
table grows, `pointer()` changes to the new contiguous pointer table and the
previous table storage remains owned by the arena, allowing publication code to
stage a replacement before exposing it. `HlMetadataGeneration` exposes the
type-record slab bounds for the loader handoff and selects the direct contiguous
publication bridge whenever its public table is an exact slab prefix; arbitrary
subset tables continue through the pointer-table adapter. The immutable
`HlMetadataPublication` records both views, the reserved slab bounds, and whether
the direct contiguous path was selected, so a future loader does not have to
reconstruct ownership facts from raw pointers.
Function descriptors follow the same pattern: `HlFunctionDescriptorTable` reserves
a stable contiguous `hl_function` array in the generation arena, while bytecode,
debug, register, and assignment pointers remain opaque until the Haxe loader owns
those representations.
Native bindings use the same ownership rule: `HlNativeDescriptorTable` reserves
a contiguous `hl_native` array and keeps its library/name pointers explicit, so
native symbol resolution can remain a later kernel operation.
Before the native publication call, `HlMetadataGeneration` validates every
function and native descriptor against the module dispatch slots and rejects
duplicate slots or mismatched signature pointers. This keeps descriptor
compatibility policy in Haxeon while the kernel remains responsible for
publication mechanics and native symbol resolution.
Reload compatibility also compares native descriptor counts, dispatch indices,
signature identities, and the bytes of their library and symbol names, so a
binding change requires an explicit structural reload.
`NativeString` provides an arena-owned, null-terminated UTF-8 value with byte
length, indexed byte access, equality, and explicit disposal. `HlStringTable`
uses the same encoding for indexed HLB strings while keeping the pointer and
length arrays in the metadata arena, so module string lifetime follows the
generation that publishes it.
`HlFunctionTable` applies the same ownership rule to module dispatch slots: its
function addresses and signature pointers are stable native arrays, with slot
replacement kept separate from table shape changes. A module context borrows
those arrays rather than allocating a second copy.
Module contexts created by `HlTypeBuilder` are also owned by the arena. If
HashLink derives runtime object metadata through a context, `reset()` and
`dispose()` release those native allocator blocks before invalidating the
arena's records.
`HlMetadataGeneration` combines these pieces into one build/publish lifecycle:
it owns the arena, appends the type table, defines the module context, lets
`HlTypeLayout` construct the derived object, enum, and virtual metadata in that
same arena, and then crosses one small native publication boundary for object
prototype wiring.
`HlTypeSemantics` centralizes the Haxe-owned size, padding, pointer-classification,
and mark-bit rules that mirror HashLink's ABI helpers; the native bridge retains
only host-width queries and bootstrap-sensitive publication operations.
Object prototype wiring remains native because it publishes executable method
and closure pointers; enum and virtual layout construction no longer calls
HashLink's native initializers, which are no longer exposed by the bridge. The
resulting runtime records, field indexes,
sorted lookups, binding slots, and mark-bit maps remain arena-owned and stable.
The view is ready for a future VM publication bridge; it does not yet replace
the native module's contiguous `hl_code.types` array.
`HlMetadataCompatibility` owns the first hot-reload policy ring: the existing
type prefix and module function-table size must remain stable, while only
primitive, abstract, and function descriptors may be appended in place. Object,
enum, virtual, and signature/layout changes return a structural-reload reason.
`HlMetadataRegistry.publish()` accepts only compatible candidates and seals them
before switching publication; `reload()` is the explicit structural path.
Both paths retire the previous generation without disposing it. Retired arenas
are drained explicitly, leaving atomic publication and concurrent borrower
tracking for the synchronization phase.
`HlMetadataTransaction` stages that decision against the registry revision:
commit transfers the candidate to the registry, while a stale or rejected
candidate remains disposable through rollback. This is the Haxe-side
transaction boundary that a future native JIT staging API can attach to.
Consumers that retain a publication use `HlMetadataRegistry.currentLease()`;
`disposeRetired()` skips generations with active leases and reports only actual
disposals. Registry shutdown likewise refuses to reclaim a borrowed current or
retired generation.
`HlFunctionVersionTable` now keeps the Haxe-side stable-ID-to-slot mapping and
the versioned entrypoint/signature state separate from those native arrays.
Its metadata adapter reads entrypoints and signature indices directly from the
generation's `HlFunctionTable`, making that mapping explicit at construction.
`HlHotReloadState` stages metadata and a complete function-version snapshot as
one single-threaded policy transaction, rejects stable slot or signature drift
for in-place patches, and exposes borrower-aware retired generations. It still
does not install executable addresses; that remains the deliberately small
native JIT/kernel boundary.

## Runtime synchronization

`runtime.memory.AtomicInt32` provides aligned unmanaged i32 operations with
explicit `MemoryOrder` values (`Relaxed`, `Acquire`, `Release`, `AcqRel`, and
`SeqCst`). Invalid load/store orderings are rejected at the Haxe boundary;
compare-exchange derives the permitted failure ordering from its success
ordering. Mutexes, condition variables, TLS, and explicit GC handles remain
separate runtime primitives, so native metadata records still contain no
implicit managed references.

## Deliberate exclusions

The first foundation does not add general-purpose allocation, ownership or
borrow checking, pinning, GC write barriers, executable memory,
`unsafe {}` syntax, indirect invocation through native function pointers,
aggregate
by-value calling conventions, or changes to the HashLink fork. The first
acceptance point is a Haxe-declared, GC-free C record whose layout agrees with
the ABI classifier, manipulated through `RawPtr<T>` in stable aligned arena
storage, with corresponding HXI layouts calculated by that same classifier.
