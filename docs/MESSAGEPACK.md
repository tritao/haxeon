# MessagePack wire layer

The `haxe.wire` package is the low-level wire layer for stable, typed
serialization. It is deliberately separate from `haxe.Serializer`: codecs
should describe the schema of a value instead of walking an object graph at
runtime.

## Current profile

- `Int` is encoded using MessagePack's compact integer markers and is limited
  to the Haxe `Int` range. `haxe.Int64` uses the same compact markers when the
  value fits in `Int`, and otherwise uses signed MessagePack `int64`. The
  compiler-owned collection ABI currently supports `Int64` as a scalar field or
  value, not as a direct array/map storage element; use a custom codec for a
  different in-memory representation.
- `Float` is written as float64. The reader accepts both float32 and float64.
- `String` is UTF-8 text; `Bytes` is MessagePack binary data.
- Arrays, maps, and application-defined extension values are available as
  explicit primitives.
- The reader has byte, container, and nesting limits. `skip()` can consume
  unknown fields for forward-compatible codecs.

The writer and reader intentionally do not expose a `Dynamic` value API. A
generated or hand-written codec chooses the wire shape and calls the matching
primitive methods. `MessagePackCodec<T>` is the boundary for such codecs.
Values outside the compiler-owned profile can use the explicit escape hatch:

```haxe
var bytes = MessagePack.encodeWith(value, codec);
var decoded:CustomType = MessagePack.decodeWith(bytes, codec);
```

`encodeWith` and `decodeWith` construct bounded writer/reader instances and
apply the same one-value rule as generated codecs.

The compiler also recognizes `MessagePack.encode(value)` and
`MessagePack.decode(bytes)` (or their fully-qualified names). Mark a plain
record with `@:wire` to have those calls lowered to type-specific functions:

```haxe
@:wire
class User {
	@:wireId(1)
	public var id:Int;
	@:wireId(2)
	public var name:String;
}

var bytes = MessagePack.encode(user);
var decoded:User = MessagePack.decode(bytes);
```

The initial compiler profile supports non-generic, non-inheriting records with
directly stored `Int`, `Int64`, `Float`, `Bool`, `String`, or `Bytes` fields, plus
nullable versions of those types, arrays of supported values, and nested
`@:wire` records. Every instance field requires one positive, unique
`@:wireId(n)` annotation. Fields are encoded as an integer-keyed map sorted by
ID and decoded by ID; this makes field renames and declaration reordering
wire-compatible. Unknown fields are skipped, missing primitive fields receive
their zero value, missing nullable fields receive `null`, and missing array
fields receive an empty array. Recursive record schemas are rejected because
the value codec does not represent object identity or cycles. `Map<String, T>`
and `Map<Int, T>` are also supported for the same value profile. String keys
are encoded and sorted lexicographically; integer keys are encoded and sorted
numerically. `Map<Enum, T>` is supported when every enum constructor is
nullary and the enum is marked `@:wire`; enum keys are encoded as their stable
constructor `@:wireId` integers and sorted by that ID. All three map forms
produce deterministic output, while missing map fields receive an empty map.
`@:wire` enums are encoded as a one-entry map from the stable constructor
`@:wireId` to an array of constructor arguments. Unknown constructor IDs and
malformed payloads are rejected. Payload-bearing enums remain unsupported as
map keys because their values are not unique by constructor index.

## Compatibility rules

Generated records and maps have deterministic output: record fields are sorted
by positive `@:wireId`, string map keys lexicographically, integer keys
numerically, and nullary enum keys by their stable constructor ID. The writer
also selects the shortest legal integer, string, array, and map marker for each
value. These rules are covered by exact byte-vector tests and are intended to
remain stable across HashLink and Wasm backends.

Decoding is permissive about field order and unknown record fields. Missing
fields receive the documented defaults. If a map or record contains a duplicate
key/field ID, the last occurrence wins. A top-level generated decode and
`decodeWith` must consume exactly one value; trailing bytes are rejected. The
low-level reader remains stream-oriented, so callers using it directly may
decode multiple consecutive values.

`readInt64()` accepts signed integer markers and unsigned `uint64` values only
when the unsigned value fits in signed `haxe.Int64`; `readInt()` continues to
reject 64-bit markers instead of silently narrowing them. A transport should
still add framing when it carries more than one value or needs message
boundaries independent of the payload.

## Example shape

A generated codec for a record uses a map with numeric field IDs:

```haxe
class UserCodec implements MessagePackCodec<User> {
	public function encode(writer:MessagePackWriter, value:User):Void {
		writer.writeMapHeader(2);
		writer.writeInt(1);
		writer.writeInt(value.id);
		writer.writeInt(2);
		writer.writeString(value.name);
	}

	public function decode(reader:MessagePackReader):User {
		var id = 0;
		var name = "";
		var fields = reader.readMapHeader();
		for (_ in 0...fields) {
			switch (reader.readInt()) {
				case 1: id = reader.readInt();
				case 2: name = reader.readString();
				default: reader.skip();
			}
		}
		return new User(id, name);
	}
}
```

MessagePack is a value encoding, not a stream framing protocol. Network or
file transports should add a length prefix or another framing layer around
one encoded value. Existing runtime/plugin state envelopes remain responsible
for their own versioning and lifecycle semantics.
