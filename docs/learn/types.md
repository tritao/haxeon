# Classes, interfaces and structures

Use a class when you want an object with fields and methods. Declare `implements Named` to let callers use a
`Book` through the `Named` interface.

Use an anonymous structure when the field names and types describe the data. `Shelf` gives that shape a name
with `typedef`. The generic function `first<T>` works with an array of any element type and returns that type.
Here the compiler infers `T` as `String` from the array.

```haxe
interface Named {
	function name():String;
}

class Book implements Named {
	final title:String;

	public function new(title:String) {
		this.title = title;
	}

	public function name():String {
		return title;
	}
}

typedef Shelf = {label:String, count:Int};

function first<T>(items:Array<T>):T {
	return items[0];
}

function main():Void {
	final book:Named = new Book("Atlas");
	final shelf:Shelf = {label: "Maps", count: 2};
	final tags = ["reference", "travel"];
	Sys.println('${shelf.label} (${shelf.count}): ${book.name()}');
	Sys.println(first(tags));
}
```

```text title="Output"
Maps (2): Atlas
reference
```

[Example project](examples/types/)

[Language support](../reference/LANGUAGE_SUPPORT.md)
