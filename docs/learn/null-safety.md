# Null safety

Use `Null<T>` when a value can be absent. `pop()` returns `null` when you call it on an empty array.
After the early return in `label`, the remaining path has a present string. Use `??` to supply a default,
as with the missing map entry here.

Enable the checker for the package in `haxeon.toml`.

```toml
entry = "Main"
nullSafety = "strict"
```

See the [null safety reference](../reference/LANGUAGE_SUPPORT.md#null-safety) for the modes and the checks they apply.

```haxe
function label(name:Null<String>):String {
	if (name == null)
		return "anonymous";
	return name.toUpperCase();
}

function main():Void {
	final names = ["Ada"];
	Sys.println(label(names.pop()));
	Sys.println(label(names.pop()));
	final counts:Map<String, Int> = ["Ada" => 3];
	final count = counts.get("Lin") ?? 0;
	Sys.println('Lin: $count');
}
```

```text title="Output"
ADA
anonymous
Lin: 0
```

[Example project](examples/null-safety/)
