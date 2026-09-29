# Generated JSON wire codec

`haxeon.wire.JsonWire.encode(value)` and `JsonWire.decode(text)` are compiler
builtins. The decoder needs an expected result type:

```haxe
var text = JsonWire.encode(value);
var restored:MyRecord = JsonWire.decode(text);
```

The generator uses the same `@:wire` declarations, `@:id(n)` assignments,
required-field checks, optional defaults, and unknown-field skipping as the
MessagePack codec. Both formats use constructor IDs for enums and field IDs
for records. JSON field keys carry a readable name after the ID; the ID is
authoritative when decoding. Renaming a field without changing its ID remains
compatible.

Version 1 JSON is an object with `version` and `value` members. Arrays are
JSON arrays. Records, enums, and maps are arrays of `[key, value]` pairs so
integer and enum map keys retain their types. A record looks like this:

```json
{"version":1,"value":[["1:name","motor"],["2:state",[["2:Moving",[[2,3]]]]]]}
```

Unknown record pairs are skipped as complete values, including nested values.
Fields required by the MessagePack schema fail when missing; missing nullable fields use `null`. The decoder
rejects unsupported versions. `Int64` and binary values use `i64:` and
`base64:` tagged strings. Nonfinite floats use `float:` tagged strings.

The generated JSON and MessagePack profiles support `@:wire` classes, enums,
and structural typedefs whose fields have `@:id(n)`, plus arrays, supported
maps, abstracts over supported values, and the supported primitive types.
Missing fields follow the same defaults and required-field rules as class
records. Two `@:wire` typedefs with the same structural type are ambiguous
and rejected. Recursive wire schemas remain unsupported.
