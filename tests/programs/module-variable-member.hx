// A member of a module-level variable read or assigned by its bare name (`seen.length`, `box.value = 4`) reads the variable.
class Box {
	public var value = 0;

	public function new() {}
}

var seen:Array<String> = [];
var box = new Box();

function main():Int {
	seen.push("a");
	var count = seen.length;
	box.value = 30;
	box.value += 10;
	box.value++;
	var shadowing = {var seen = "local";
	seen.length;
	};
	return count + seen.length + box.value - shadowing + 4;
}
