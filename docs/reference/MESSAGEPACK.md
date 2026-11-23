# MessagePack wire layer

The `haxeon.wire` package is the low-level wire layer for stable, typed
serialization. It is deliberately separate from `haxe.Serializer`: codecs
should describe the schema of a value instead of walking an object graph at
runtime.

## Frozen v1 public API

The frozen v1 surface is the `haxeon.wire.*` package, the `@:wire` type
metadata, and the `@:id(n)` field or enum-constructor metadata. There are no
compatibility aliases for the pre-v1 names. These names and the canonical byte
rules below are the public serialization contract.

## Current profile

- `Int` is encoded using MessagePack's compact integer markers and is limited
  to the Haxe `Int` range. `haxe.Int64` uses the same compact markers when the
  value fits in `Int`, emits unsigned `uint32` for positive values through
  `4294967295`, and otherwise uses signed MessagePack `int64`. The
  compiler-owned collection ABI stores `Int64` arrays and map values as native
  64-bit elements.
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
import haxeon.wire.MessagePack;

@:wire
class User {
	@:id(1)
	public var id:Int;
	@:id(2)
	public var name:String;
}

var bytes = MessagePack.encode(user);
var decoded:User = MessagePack.decode(bytes);
```

The initial compiler profile supports non-generic, non-inheriting records with
directly stored `Int`, `Int64`, `Float`, `Bool`, `String`, or `Bytes` fields, plus
nullable versions of those types, arrays of supported values, and nested
`@:wire` records. Fields may be `final` or mutable. Every instance field requires
one positive, unique `@:id(n)` annotation. IDs are permanent schema identities: once an ID has been
used for a field or enum constructor, it must never be reused for a different
semantic member. Deleting a member reserves its old ID forever.

Fields are encoded as an integer-keyed map sorted by ID and decoded by ID; this
makes field renames and declaration reordering wire-compatible. Unknown fields
are skipped. Missing integers, floats, and booleans receive `0`, `0.0`, and
`false`; missing strings receive their existing empty-string default, nullable
values receive `null`, and missing arrays and maps receive empty collections.
Missing non-null records and enums are errors unless the field has a supported
initializer. Supported field initializers are literals, `null`, enum
constructors, and simple array/map literals; the generated decoder evaluates
these defaults directly and never invokes a record constructor. The decoder
validates required fields, then initializes each field once before returning the
new record. Unsupported
initializer expressions are rejected by the compiler. Recursive record schemas
are rejected because the value codec does not represent object identity or
cycles.

`Map<String, T>` and `Map<Int, T>` are also supported for the same value
profile. String keys are encoded as UTF-8 and ordered by lexicographic
comparison of those UTF-8 bytes; integer keys are encoded and sorted
numerically. `Map<Enum, T>` is supported when every enum constructor is nullary
and the enum is marked `@:wire`; enum keys are encoded as their stable
constructor `@:id` integers and sorted by that ID. All three map forms produce
deterministic output, while missing map fields receive an empty map.
`@:wire` enums are encoded as a one-entry map from the stable constructor
`@:id` to an array of constructor arguments. Unknown constructor IDs and
malformed payloads are rejected. Adding an enum constructor is therefore not
forward-compatible with older readers if the new value can reach them.
Payload-bearing enums remain unsupported as map keys because their values are
not unique by constructor index.

## Compatibility rules

Generated records and maps have deterministic output: record fields are sorted
by positive `@:id`, string map keys by UTF-8 byte lexicographic order, integer
keys numerically, and nullary enum keys by their stable constructor ID. The
writer also selects the shortest legal integer, string, array, and map marker
for each value. These rules are covered by exact byte-vector tests and are
intended to remain stable across HashLink and Wasm backends.

Decoding is permissive about field order and unknown record fields. Missing
fields receive the documented defaults, or fail when a required record/enum
field has no explicit default. If a map or record contains a duplicate
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
import haxeon.wire.MessagePackCodec;
import haxeon.wire.MessagePackReader;
import haxeon.wire.MessagePackWriter;

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

MessagePack is a value encoding, not a stream framing protocol. For a simple
transport boundary, `haxeon.wire.MessagePackFrame` provides a fixed versioned
envelope:

```text
HMPK | version:u8 | flags:u8 | payloadLength:u32be | payload
```

`MessagePackFrame.CURRENT_VERSION` is `1`; version 1 requires flags to be
zero, rejects truncation and trailing bytes, and applies the same bounded
payload limit as `MessagePackReader` by default. It frames exactly one
MessagePack value but does not replace `MessagePack.decode`'s exact-value
validation:

```haxe
import haxeon.wire.MessagePackFrame;

var frame = MessagePackFrame.pack(MessagePack.encode(user));
var bytes = MessagePackFrame.unpack(frame);
var decoded:User = MessagePack.decode(bytes);
```

Existing runtime/plugin state envelopes remain responsible for their own
versioning and lifecycle semantics when they need a different contract.

## Descriptor sidecars

`haxeon.wire.MessagePackSchema` reads the `.descriptors.json` artifact the
compiler emits for `typeInfo<T>()` roots: a descriptor for each struct, with its name, each field's name, type and
typed annotations (and for a flat struct its size, alignment and field offsets), and a content hash over all of them.
`fromJson` validates every descriptor, including its content hash, before
anything is read from it. Each query takes the hash and the semantic type of
the same `typeInfo<T>()` identity:

```haxe
var schema = MessagePackSchema.fromJson(File.getContent(descriptorPath));
var info = typeInfo<MyResource>();
schema.requireDescriptor(info.hash, info.type);
var facts = schema.requireSourceFacts(info.hash, info.type);
var initial = schema.fieldDefaultValue(info.hash, info.type, ["limits", "max"]);
```

- `fieldDefaultValue(hash, type, path)` returns the declared default of a root
  or nested field. `null` means the field has no initializer; an explicit
  nullable null is `{type: "Null", value: null}`.
- `Int32` and `UInt32` defaults are exact 32-bit `Int` carrier values, so a
  `UInt32` with all bits set is written and read as `-1`. The literal
  `4294967295` is outside the `Int` range and is rejected with E0002.
- `sourceFacts(hash, type)` returns the declaration's `sourceKind` (`Struct`,
  `Class` or `NativeValue`) and `interfaces`: sorted, deduplicated
  `SemanticSignature.type` identities of the declared and inherited
  interfaces after generic substitution, for example
  `interface:domain.Base<Int>`. `typeInfo<T>()` exposes the same two fields.
- `sourceFacts` returns `null` for an older descriptor that has no facts, and
  `requireSourceFacts` throws, so missing metadata is not read as
  nonconformance.

Current artifacts use JSON envelope format 4 with descriptor version 5.
`MessagePackSchema` also accepts envelope format 3 with descriptor version 4,
whose source facts are unknown. The hash check proves the fields agree with the
compiler's hash algorithm. It does not authenticate the producer, and the facts
describe source declarations, not a loaded binary.
`tests/integration/test-type-descriptor-artifact.sh` covers the artifact.

## Interoperability checks

The canonical MessagePack values live in
`tests/fixtures/messagepack-vectors.tsv`; the framed envelope cases live in
`tests/fixtures/messagepack-frame-vectors.tsv`. The
`messagepack-interop` program decodes and re-encodes the canonical bytes with
the Haxe reader and writer. `tests/integration/test-messagepack-interop.sh` additionally
uses Python's `msgpack` package to decode every canonical value, produce
compatible encodings, and validate framed payloads. The Python portion is
optional for local runs and is installed in the Ubuntu CI jobs.
