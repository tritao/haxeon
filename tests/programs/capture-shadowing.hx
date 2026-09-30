// Captured variables are told apart by declaration: writing a same-named variable elsewhere does not turn a read-only
// capture into a shared one, and a real mutable capture still shares its cell.
function main():Int {
	var x = 1;
	var read = function():Int return x;
	{
		var x = 100;
		x = 101;
		x++;
	}
	var y = 10;
	var adder = function():Void {
		var y = 0;
		y = 5;
		y += 1;
	};
	adder();
	var total = 0;
	var bump = function():Void {
		total = total + 1;
	};
	bump();
	bump();
	var nested = function():Int {
		var inner = function():Void {
			total = total + 10;
		};
		inner();
		return total;
	};
	if (read() != 1 || y != 10)
		return 1;
	if (nested() != 12 || total != 12)
		return 2;
	x = 30;
	return read() + total;
}
