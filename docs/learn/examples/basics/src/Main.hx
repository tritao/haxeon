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
