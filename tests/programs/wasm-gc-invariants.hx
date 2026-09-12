class GcRootProbe {
	public var value:Int;

	public function new() {}
}

class GcCycleProbe {
	public var value:Int;
	public var next:GcCycleProbe;

	public function new() {}
}

class GcClosureProbe {
	public var value:Int;

	public function new() {}

	public function read():Int {
		return value;
	}
}

enum GcEnumProbe {
	Probe(value:GcRootProbe);
	Empty;
}

function releaseLargeArray():Void {
	var values = new Array<Int>(1024);
	values[0] = 7;
}

function reallocateLargeArray():Int {
	var values = new Array<Int>(1024);
	values[0] = 42;
	return values.length;
}

function allocationBurst(count:Int):Int {
	var index = 0;
	while (index < count) {
		var probe = new GcRootProbe();
		probe.value = index;
		index = index + 1;
	}
	return 42;
}

function growBeyondInitialMemory():Int {
	var values = new Array<Int>(20000);
	return values.length;
}

function referenceArrayRootExercise():Int {
	var values = new Array<GcRootProbe>(40);
	var index = 0;
	while (index < 40) {
		var probe = new GcRootProbe();
		probe.value = index;
		values[index] = probe;
		index = index + 1;
	}
	return values[39].value;
}

function referenceArrayGrowthExercise():Int {
	var values:Array<GcRootProbe> = [];
	var index = 0;
	while (index < 40) {
		var probe = new GcRootProbe();
		probe.value = index;
		values.push(probe);
		index = index + 1;
	}
	return values[39].value;
}

function cycleExercise():Int {
	var first = new GcCycleProbe();
	var second = new GcCycleProbe();
	first.value = 39;
	first.next = second;
	second.next = first;
	var index = 0;
	while (index < 8) {
		var garbage = new GcRootProbe();
		index = index + 1;
	}
	return first.next.next.value;
}

function enumRootExercise():Int {
	var probe = new GcRootProbe();
	probe.value = 39;
	var value:GcEnumProbe = Probe(probe);
	var index = 0;
	while (index < 8) {
		var garbage = new GcRootProbe();
		index = index + 1;
	}
	return switch value {
		case Probe(held): held.value;
		case Empty: 0;
	};
}

function closureRootExercise():Int {
	var probe = new GcClosureProbe();
	probe.value = 39;
	var callback:() -> Int = probe.read;
	var index = 0;
	while (index < 8) {
		var garbage = new GcRootProbe();
		index = index + 1;
	}
	return callback();
}

function iteratorRootExercise():Int {
	var values:Array<GcRootProbe> = [];
	var probe = new GcRootProbe();
	probe.value = 39;
	values.push(probe);
	var iterator = values.iterator();
	var index = 0;
	while (index < 8) {
		var garbage = new GcRootProbe();
		index = index + 1;
	}
	return iterator.next().value;
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
