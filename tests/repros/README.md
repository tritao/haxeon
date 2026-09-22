# JSON dynamic-array cast regression

From the repository root, compile and run:

```sh
haxeon/.tools/haxe/haxe --cwd haxeon -cp src --run Main tests/programs/json-typed-object-array.hx out/json-typed-object-array.hl
LD_LIBRARY_PATH="$PWD/haxeon/out:$PWD/haxeon/.tools/hashlink" haxeon/.tools/hashlink/hl haxeon/out/json-typed-object-array.hl
```

The JSON parser creates an `Array<Dynamic>` of dynamic objects. Assigning the
result to `Array<Item>` does not materialize `Item` records. The runtime now
rejects that cast before a typed field read. The conversion path is covered by
`tests/programs/json-decoded-object-array.hx`: validate each field and create
a new typed value.

Do not treat `__string_equal` or `ustrlen` as the cause. The array cast must
check the element representation before indexed reads or writes.
