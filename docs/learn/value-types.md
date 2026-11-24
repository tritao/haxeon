# Structs and value equality

Use a `struct` when you want assignment to copy the value. Changing the copy's column leaves the original's own
column at 5.

Declare `implements Equatable` to use `==` and `!=` on a struct. Use `Hashable` when you also want to use that
value as a map key. The compiler generates equality and hashing for `Cell` from its integer fields, so a new
cell with the same coordinates finds the existing entry.

```haxe
struct Cell implements Hashable {
	public var row:Int;
	public var column:Int;

	public function new(row:Int, column:Int) {
		this.row = row;
		this.column = column;
	}
}

function main():Void {
	final original = new Cell(2, 5);
	var copy = original;
	copy.column = 6;
	Sys.println(original.column);
	Sys.println(copy == original);
	final names:Map<Cell, String> = [original => "start"];
	Sys.println(names.get(new Cell(2, 5)) ?? "missing");
}
```

```text title="Output"
5
false
start
```

[Example project](examples/value-types/)

[Declared value equality](../reference/STRUCTURAL_EQUALITY.md) and [native values and memory](../reference/NATIVE_MEMORY.md)
