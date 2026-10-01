// A field of a Dynamic value is read and written by name when the program runs, and what is read is Dynamic.
class Point {
	public var x:Int = 1;
	public var label:String = "p";

	public function new() {}
}

function describe():Dynamic
	return {inner: {depth: 2}, name: "root"};

function main():Int {
	var typed:Dynamic = new Point();
	var anonymous:Dynamic = {count: 3, title: "t"};
	var nested:Dynamic = describe();
	var x:Int = typed.x;
	typed.x = 41;
	var changed:Int = typed.x;
	var label:String = typed.label;
	typed.label = "q";
	var relabelled:String = typed.label;
	var count:Int = anonymous.count;
	anonymous.count = 9;
	anonymous.added = "new";
	var added:String = anonymous.added;
	var depth:Int = nested.inner.depth;
	nested.inner.depth = 5;
	var deeper:Int = nested.inner.depth;
	var name:String = nested.name;
	var missing:Dynamic = anonymous.missing;
	var copy:Int = anonymous.count;
	var viaAssignmentValue:Int = 0;
	var chained:Dynamic = typed.x = 7;
	viaAssignmentValue = typed.x;
	var checks = [
		x == 1,
		changed == 41,
		label == "p",
		relabelled == "q",
		count == 3,
		copy == 9,
		added == "new",
		depth == 2,
		deeper == 5,
		name == "root",
		missing == null,
		viaAssignmentValue == 7
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
