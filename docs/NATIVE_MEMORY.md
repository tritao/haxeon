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
HashLink; it does not change the HashLink fork. HXI-imported records already
share the native ABI layout classifier, while unifying their public pointer and
record projections is still future work.

HashLink metadata tables use `runtime.hashlink.HlTypeTable`. Adding a type
allocates only a new pointer slot; the `hl_type` record itself remains in the
arena at a stable address. When the table grows, `pointer()` changes to the new
contiguous table and the previous table storage remains owned by the arena,
allowing publication code to stage a replacement before exposing it.
Module contexts created by `HlTypeBuilder` are also owned by the arena. If
HashLink derives runtime object metadata through a context, `reset()` and
`dispose()` release those native allocator blocks before invalidating the
arena's records.

## Deliberate exclusions

The first foundation does not add general-purpose allocation, ownership or
borrow checking, pinning, GC write barriers, atomics, TLS, executable memory,
`unsafe {}` syntax, arbitrary native function pointers, aggregate
by-value calling conventions, or changes to the HashLink fork. The first
acceptance point is a Haxe-declared, GC-free C record whose layout agrees with
the ABI classifier, manipulated through `RawPtr<T>` in stable aligned arena
storage, with corresponding HXI layouts calculated by that same classifier.
