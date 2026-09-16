# MessagePack wire layer

The `haxe.wire` package is the low-level wire layer for stable, typed
serialization. It is deliberately separate from `haxe.Serializer`: codecs
should describe the schema of a value instead of walking an object graph at
runtime.

## Current profile

- `Int` is encoded using MessagePack's compact integer markers and is limited
  to the Haxe `Int` range. Int64 support belongs in a separate typed codec.
- `Float` is written as float64. The reader accepts both float32 and float64.
- `String` is UTF-8 text; `Bytes` is MessagePack binary data.
- Arrays, maps, and application-defined extension values are available as
  explicit primitives.
- The reader has byte, container, and nesting limits. `skip()` can consume
  unknown fields for forward-compatible codecs.

The writer and reader intentionally do not expose a `Dynamic` value API. A
generated or hand-written codec chooses the wire shape and calls the matching
primitive methods. `MessagePackCodec<T>` is the boundary for such codecs.

The compiler also recognizes `MessagePack.encode(value)` and
`MessagePack.decode(bytes)` (or their fully-qualified names). Mark a plain
record with `@:wire` to have those calls lowered to type-specific functions:

```haxe
@:wire
class User {
	public var id:Int;
	public var name:String;
}

var bytes = MessagePack.encode(user);
var decoded:User = MessagePack.decode(bytes);
```

The initial compiler profile supports non-generic, non-inheriting records with
directly stored `Int`, `Float`, `Bool`, `String`, or `Bytes` fields. Fields are
encoded as a map in declaration order and decoded by field name; unknown
fields are skipped and missing primitive fields receive their zero value.
This restriction is intentional while enum, nullable, collection, and
explicit field-ID policies are added to the generator.

## Example shape

A generated codec for a record should normally use a map with stable field
names or numeric field IDs:

```haxe
class UserCodec implements MessagePackCodec<User> {
	public function encode(writer:MessagePackWriter, value:User):Void {
		writer.writeMapHeader(2);
		writer.writeString("id");
		writer.writeInt(value.id);
		writer.writeString("name");
		writer.writeString(value.name);
	}

	public function decode(reader:MessagePackReader):User {
		var id = 0;
		var name = "";
		var fields = reader.readMapHeader();
		for (_ in 0...fields) {
			switch (reader.readString()) {
				case "id": id = reader.readInt();
				case "name": name = reader.readString();
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
