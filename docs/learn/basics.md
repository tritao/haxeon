# Values and functions

Use `final` for a binding you assign once and `var` for a binding you can reassign. Here the initializer gives
`item` the type `String` and `quantity` the type `Int`. The function declares the types of its parameters and
the compiler infers its return type from the multiplication.

Use single quotes for string interpolation. Write `$name` for a variable and `${expression}` for an expression.
A program starts at `main`.

```haxe
function subtotal(unitPrice:Int, quantity:Int) {
	return unitPrice * quantity;
}

function main():Void {
	final item = "notebook";
	var quantity = 2;
	quantity += 1;
	final total = subtotal(4, quantity);
	Sys.println('$quantity × $item = ${total} credits');
}
```

```text title="Output"
3 × notebook = 12 credits
```

[Example project](examples/basics/)

[Language support](../reference/LANGUAGE_SUPPORT.md)
