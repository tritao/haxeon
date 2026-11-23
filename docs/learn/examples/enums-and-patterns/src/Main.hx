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
