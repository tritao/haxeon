package compiler.compilation;

/**
 * Allocation of each IR pass in one compile, in the order the passes first ran, for the driver's timings line. A pass that runs more
 * than once (value phi scalarization runs between other passes) is summed under one name. `measure` costs two meter samples per call.
 */
class IrPassMeter {
	static var order:Array<String> = [];
	static var bytes:Map<String, Float> = [];
	static var counts:Map<String, Float> = [];

	public static function reset():Void {
		order = [];
		bytes = [];
		counts = [];
	}

	public static function measure<T>(name:String, run:Void->T):T {
		var before = AllocationMeter.sample();
		var result = run();
		record(name, before, AllocationMeter.sample());
		return result;
	}

	public static function measureVoid(name:String, run:Void->Void):Void {
		var before = AllocationMeter.sample();
		run();
		record(name, before, AllocationMeter.sample());
	}

	static function record(name:String, before:AllocationMeter.AllocationSnapshot, after:AllocationMeter.AllocationSnapshot):Void {
		if (!bytes.exists(name))
			order.push(name);
		bytes.set(name, (bytes.exists(name) ? bytes.get(name) : 0.0) + after.bytes - before.bytes);
		counts.set(name, (counts.exists(name) ? counts.get(name) : 0.0) + after.count - before.count);
	}

	/** One entry per pass: name, bytes, objects. */
	public static function entries():Array<{name:String, bytes:Float, count:Float}> {
		var result:Array<{name:String, bytes:Float, count:Float}> = [];
		for (name in order) {
			var passBytes = bytes.get(name), passCount = counts.get(name);
			result.push({name: name, bytes: passBytes == null ? 0.0 : passBytes, count: passCount == null ? 0.0 : passCount});
		}
		return result;
	}
}
