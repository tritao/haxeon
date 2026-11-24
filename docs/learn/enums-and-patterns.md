# Enums and pattern matching

Declare an enum when a value can take one of several forms. `Pickup` carries no payload. `Courier` carries
the destination address.

Use a `switch` to handle each form. A structure pattern checks the fields you name. The first case checks only
`paid`, so it also matches unpaid courier orders. In the final case, `Courier(address)` tests the constructor and
binds its payload. The cases cover every `Order` in this example, so you can use the switch as a value without a
default.

```haxe
enum Delivery {
	Pickup;
	Courier(address:String);
}

typedef Order = {delivery:Delivery, paid:Bool};

function describe(order:Order):String {
	return switch (order) {
		case {
			paid:false
		}
		: "Awaiting payment";
		case {
			paid:true, delivery:Pickup
		}
		: "Ready for pickup";
		case {
			paid:true, delivery:Courier(address)
		}
		: 'Send to $address';
	};
}

function main():Void {
	Sys.println(describe({delivery: Pickup, paid: false}));
	Sys.println(describe({delivery: Pickup, paid: true}));
	Sys.println(describe({delivery: Courier("8 Oak Street"), paid: true}));
}
```

```text title="Output"
Awaiting payment
Ready for pickup
Send to 8 Oak Street
```

[Example project](examples/enums-and-patterns/)

[Language support](../reference/LANGUAGE_SUPPORT.md)
