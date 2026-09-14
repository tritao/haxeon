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
closures, `Dynamic`, and all other GC-managed references are rejected. Fixed
arrays and automatic field syntax are not implemented yet.

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
```

Pointer offsets and memory accesses are explicit SSA instructions. HL lowering
uses HashLink's existing untyped memory opcodes; byte offsets use its existing
`std.bytes_offset` operation. Native record fields are accessed by adding the
constant returned by `offsetof<T>("field")` and casting to a pointer to the
field type. For a pointer-valued field, that means a `RawPtr<RawPtr<U>>` to load
or store the `RawPtr<U>` value.

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
positive, and the current implementation supports alignments up to 16 bytes.
There is no individual `free` operation.

Haxeon performs layout-based alignment, bump advancement, block growth, and
reset. The only new native runtime operations acquire and release raw backing
blocks with `malloc` and `free`. This implementation currently targets
HashLink; it does not change the HashLink fork. HXI-imported records already
share the native ABI layout classifier, while unifying their public pointer and
record projections is still future work.

## Deliberate exclusions

The first foundation does not add general-purpose allocation, ownership or
borrow checking, pinning, GC write barriers, atomics, TLS, executable memory,
`unsafe {}` syntax, fixed arrays, automatic `p.ref.field` access, aggregate
by-value calling conventions, or changes to the HashLink fork. The first
acceptance point is a Haxe-declared, GC-free C record whose layout agrees with
the ABI classifier, manipulated through `RawPtr<T>` in stable aligned arena
storage, with corresponding HXI layouts calculated by that same classifier.
