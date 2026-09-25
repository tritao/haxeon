# JSON dynamic-array cast regression

From the repository root, compile and run:

```sh
haxeon/.tools/haxe/haxe --cwd haxeon -cp src --run Main tests/programs/json-typed-object-array.hx out/json-typed-object-array.hl
LD_LIBRARY_PATH="$PWD/haxeon/out:$PWD/haxeon/.tools/hashlink" haxeon/.tools/hashlink/hl haxeon/out/json-typed-object-array.hl
```

The JSON parser creates an `Array<Dynamic>` of dynamic objects. Arrays created
for dynamic values take their element type on the first concrete view, so
assigning the result to `Array<Item>` validates every element and rejects the
dynamic objects before any typed field read, leaving the array unchanged. The
conversion path is covered by `tests/programs/json-decoded-object-array.hx`:
validate each field and create a new typed value.

`Array<Dynamic>` accepts storage of any element type and converts on each read
and write; exact storage of one type is never viewed as another. See
`tests/programs/generic-array-storage.hx`.

Do not treat `__string_equal` or `ustrlen` as the cause.
