class GcRootProbe {
	public var value:Int;

	public function new() {}
}

function releaseLargeArray():Void {
	var values = new Array<Int>(1024);
	values[0] = 7;
}

function releaseArray(size:Int):Void {
	var values = new Array<Int>(size);
	if (size > 0)
		values[0] = size;
}

function exercise(count:Int):Int {
	var index = 1;
	while (index <= count) {
		releaseArray(index);
		index = index + 1;
	}
	return 42;
}

function consumeRoot(root:GcRootProbe):Void {
	if (root.value < 0)
		throw "invalid-root-value";
}

function rootSnapshotExercise():Int {
	var held = new GcRootProbe();
	consumeRoot(held);
	var transient = new GcRootProbe();
	if (transient == null)
		return 0;
	return 42;
}

function throwFromRootedHelper(root:GcRootProbe):Void {
	var nested = new GcRootProbe();
	if (root != null && nested != null)
		throw "gc-root-unwind";
}

function throwThroughRoots():Void {
	var root = new GcRootProbe();
	throwFromRootedHelper(root);
}

function main():Int {
	releaseLargeArray();
	releaseArray(1);
	return 42;
}
