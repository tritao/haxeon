# Generated JSON wire codec

`haxeon.wire.JsonWire.encode(value)` and `JsonWire.decode(text)` are compiler
builtins. Decoding returns a `Result<T, WireError>`, as
[MessagePack](MESSAGEPACK.md) decoding does, and the expected type names `T`:

```haxe
var text = JsonWire.encode(value);
var restored:Result<MyRecord, WireError> = JsonWire.decode(text);
```

Codecs are inferred from those calls, including the supported types nested in
records, enums, arrays, and maps. JSON uses the same key mode, defaults and
required-field rules as [MessagePack](MESSAGEPACK.md). Unknown record members
are skipped as complete values, including nested values.

The envelope has `version: 1` and a `value` member. Arrays are JSON arrays.
Name-keyed records are JSON objects, with members written in declaration order.
Structurally identical unannotated typedefs use the same schema and field
order. Records without a declaration use the compiler's canonical field order.
Name-keyed enums are one-property objects from the
constructor name to an array of its arguments:

```json
{"version":1,"value":{"name":"motor","state":{"Moving":[[2,3]]}}}
```

Numbered records and enums keep the frozen v1 array-of-pairs shape. The ID in
each `"id:name"` key is authoritative, so the readable name may change:

```json
{"version":1,"value":[["1:name","motor"],["2:state",[["2:Moving",[[2,3]]]]]]}
```

Each declaration chooses its own shape, so a named record can contain a
numbered enum or vice versa. Maps of any supported key type are arrays of
pairs. Enum map keys are constructor names for named enums and integers for
numbered enums. The decoder rejects unsupported envelope versions. `Int64`
and binary values use `i64:` and `base64:` tagged strings. Nonfinite floats
use `float:` tagged strings. Recursive schemas remain unsupported.

## Data that must last: pin IDs

Run `haxeon lint --fix --pin-wire TYPE FILE` to write explicit IDs and add
`@:wire`. Pinned records and enums encode as numbered arrays of pairs and
also decode existing name-keyed objects by matching the current field and
constructor names. Pinned enum map keys also accept constructor names on
input. Keep names in use by stored name-keyed data until those values have
been rewritten with IDs. The same structural typedef ambiguity rule applies
in both formats.
