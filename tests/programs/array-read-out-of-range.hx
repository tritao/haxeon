// Haxeon is stricter than Haxe here (docs/reference/LANGUAGE_SUPPORT.md): a read at a negative index or at or past the length
// throws, for every element type, where Haxe returns a target-dependent value. A write past the end grows the array as in Haxe,
// and a write at a negative index throws.
function throws(read:() -> Dynamic):Bool {
	try {
		read();
	} catch (_:Dynamic) {
		return true;
	}
	return false;
}

function main():Int {
	var ints = [1, 2], floats = [1.5], bools = [true], strings = ["a"], dynamics:Array<Dynamic> = [1];
	var nullable:Array<Null<String>> = [], empty:Array<Int> = [];
	if (!throws(() -> ints[2]) || !throws(() -> ints[-1]) || !throws(() -> empty[0]))
		return 1;
	if (!throws(() -> floats[1]) || !throws(() -> bools[1]))
		return 2;
	if (!throws(() -> strings[1]) || !throws(() -> nullable[3]) || !throws(() -> dynamics[4]))
		return 3;
	ints[4] = 5;
	if (ints.length != 5 || ints[2] != 0 || ints[3] != 0 || ints[4] != 5)
		return 4;
	nullable[2] = "c";
	if (nullable.length != 3 || nullable[0] != null || nullable[2] != "c")
		return 5;
	if (!throws(() -> ints[-1] = 3) || ints.length != 5)
		return 6;
	// The porting form of Haxe's read.
	var index = 7;
	var value = index < nullable.length ? nullable[index] : null;
	if (value != null)
		return 7;
	return 42;
}
