class UnshiftItem {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

class UnshiftHolder {
	public var values:Array<Int>;

	public function new() {
		this.values = [41];
	}
}

function main():Int {
	var integers = [2];
	if (integers.unshift(1) != 2 || integers[0] != 1)
		return 0;
	var floats = [2.0];
	floats.unshift(1.0);
	if (floats[0] != 1.0)
		return 0;
	var booleans = [false];
	booleans.unshift(true);
	if (!booleans[0])
		return 0;
	var strings = ["second"];
	strings.unshift("first");
	if (strings[0] != "first")
		return 0;
	var objects = [new UnshiftItem(2)];
	objects.unshift(new UnshiftItem(1));
	if (objects[0].value != 1)
		return 0;
	var holder = new UnshiftHolder();
	holder.values.unshift(1);
	return holder.values[0] + holder.values[1];
}
