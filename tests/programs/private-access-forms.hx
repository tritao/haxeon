// `@:privateAccess` on a statement, a block and an expression reaches private members, as in Haxe; metadata arguments follow the name
// directly, so with a space `@:privateAccess (a + b)` and `@:keep (1 + 2)` are metadata on a parenthesized expression.
class Item {
	var secret:Int = 1;

	public function new() {}

	function hidden():Int
		return 2;
}

function main():Int {
	var item = new Item();
	@:privateAccess item.secret = 5;
	@:privateAccess {
		item.secret += 1;
		var bound = item.hidden;
		item.secret += bound();
	}
	var total = @:privateAccess (item.secret + item.hidden());
	var kept = @:keep (1 + 2);
	return total == 10 && kept == 3 ? 42 : 1;
}
