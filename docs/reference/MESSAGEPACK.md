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
var decoded:Result<CustomType, WireError> = MessagePack.decodeWith(bytes, codec);
```

`encodeWith` and `decodeWith` construct bounded writer/reader instances and
apply the same one-value rule as generated codecs. A codec fails a decode by
throwing a `WireFailure`, as the reader does, and `decodeWith` returns its
`WireError`.

The compiler also recognizes `MessagePack.encode(value)` and
`MessagePack.decode(bytes)` (or their fully-qualified names). The compiler
generates a codec for the concrete type of the value or the expected result,
including the supported types it contains. This happens only for types reached
from wire calls, including `JsonWire`, `RpcMethod.wire`, and
[typed RPC services](RPC.md):

```haxe
import haxeon.wire.MessagePack;

class User {
	public var id:Int;
	public var name:String;

	public function new(id:Int, name:String) {
		this.id = id;
		this.name = name;
	}
}

var bytes = MessagePack.encode(new User(7, "Ada"));
var decoded:Result<User, WireError> = MessagePack.decode(bytes);
```

Decoding returns a `Result`, since bytes from elsewhere may not hold a value of
the expected type. The codec is generated for the `Result`'s value type, so the
expected type names it: a typed local, as above, or `try` in a function that
returns a `Result` with the same error type (`var user:User = try
MessagePack.decode(bytes);`). A decode the `Result` is not expected of, such as
the subject of a `switch` or the receiver of `.mapErr(f)`, needs the typed local.
The `Err` is a `WireError`:

- `Truncated`: the input ends inside a value.
- `TrailingData`: another value follows the one decoded.
- `Malformed(reason)`: the input is not MessagePack, or not the shape the type
  expects there, such as a string where a record goes.
- `LimitExceeded(reason)`: the input, a container or its nesting is over a
  reader limit.
- `IncompatibleSchema(reason)`: a writer descriptor is missing or damaged.

Encoding does not fail for expected reasons: a writer that is misused, or whose
output is over its limit, throws.

The compiler supports non-generic, non-inheriting classes and structs,
structural records, and enums. Fields must have direct storage and can use
`Int`, `Int64`, `Float`, `Bool`, `String`, `Bytes`, supported abstracts,
nullable values, arrays, maps, and other supported records and enums. Fields
may be final or mutable. An unsupported member type is a compile error.

A record without IDs is a map keyed by field-name strings, ordered
lexicographically by UTF-8 bytes. An enum without IDs is a one-entry map
from the constructor name string to its array of arguments. Integer keys
identify the original numbered shapes. Each declaration uses a single key
mode. If any member has an ID, every member must have a positive, unique ID.
Unknown record keys are skipped in either mode. Missing integers, floats, and booleans receive `0`, `0.0`, and
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
and its codec is inferred along with the map. Enum keys use constructor names
or explicit IDs, ordered by UTF-8 bytes or numeric ID, respectively. All three map forms produce
deterministic output, while missing map fields receive an empty map.
Numbered enums encode a one-entry map from the stable constructor
`@:id` to an array of constructor arguments. Unknown constructor names or IDs and
malformed payloads are rejected. Adding an enum constructor is therefore not
forward-compatible with older readers if the new value can reach them.
Payload-bearing enums remain unsupported as map keys because their values are
not unique by constructor index.

## Data that must last: pin IDs

```sh
haxeon lint --fix --pin-wire User src/User.hx
```

The fix adds `@:wire` and writes consecutive `@:id(n)` annotations, starting at
1, on instance fields or enum constructors in declaration order. Rerunning it
preserves existing IDs. Run it separately for each nested declaration whose
schema needs permanent member identities. The compiler only uses explicit
IDs and never derives them from declaration order.

Pinned types encode integer keys and also decode existing name-keyed data by
matching the current field and constructor names, including enum map keys.
Keep names in use by stored name-keyed data until those values have been
rewritten with IDs. Numbered record fields are sorted by ID, which stays
attached to the same semantic field through renames and reordering. Keep
deleted IDs reserved and give new members fresh IDs.

Structurally identical unannotated typedefs share a name-keyed schema. An
explicit wire typedef (one with `@:wire` or member IDs) supplies the schema
for its structure. Two explicit wire typedefs of the same structural type
are ambiguous. Use nominal classes or structs when identical field shapes
need distinct schemas.

## Compatibility rules

The writer selects the shortest legal integer, string, array, and map marker
for each value. Exact byte-vector tests cover the stable numbered format.

Decoding is permissive about field order and unknown record fields. Missing
fields receive the documented defaults, or fail when a required record/enum
field has no explicit default. If a map or record contains a duplicate
key, the last occurrence wins. A top-level generated decode and
`decodeWith` must consume exactly one value; trailing bytes are `TrailingData`. The
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
var bytes = try MessagePackFrame.unpack(frame);
var decoded:User = try MessagePack.decode(bytes);
```

`unpack`, `payloadLength` and `MessagePackFrameReader.feed` return a `Result`
with the same `WireError`; after a malformed frame the frame reader takes no
more input.

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
var schema = try MessagePackSchema.fromJson(File.getContent(descriptorPath));
var info = typeInfo<MyResource>();
try schema.requireDescriptor(info.hash, info.type);
var facts = try schema.requireSourceFacts(info.hash, info.type);
var initial = try schema.fieldDefaultValue(info.hash, info.type, ["limits", "max"]);
```

`fromJson` and each query return a `Result` whose `Err` is a `WireError`,
`IncompatibleSchema` for a descriptor that is damaged or absent.

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
- `sourceFacts` gives `null` for an older descriptor that has no facts, and
  `requireSourceFacts` an `Err`, so missing metadata is not read as
  nonconformance.

Current artifacts use JSON envelope format 4 with descriptor version 5.
`MessagePackSchema` also accepts envelope format 3 with descriptor version 4,
whose source facts are unknown. The hash check proves the fields agree with the
compiler's hash algorithm. It does not authenticate the producer, and the facts
describe source declarations, not a loaded binary.
