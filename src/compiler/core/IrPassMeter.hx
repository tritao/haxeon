package compiler.core;

/** One IR pass's allocation in one compile. */
typedef IrPassAllocation = {
	final name:String;
	final bytes:Float;
	final count:Float;
}

/**
 * Allocation of each IR pass in one compile, in the order the passes first ran, for the driver's timings line. A pass that runs more
 * than once (value phi scalarization runs between other passes) is summed under one name. A pass costs two meter samples: `start` and
 * `stop`, called by the stages `compiler.ir.IrPipeline` meters. Each compile's pipeline has its own (`IrPipelineContext.meter`).
 */
class IrPassMeter {
	final order:Array<String> = [];
	final bytes:Map<String, Float> = [];
	final counts:Map<String, Float> = [];

	public function new() {}

	/** The sample `stop` measures from. */
	public function start():AllocationMeter.AllocationSnapshot
		return AllocationMeter.sample();

	/** Records what was allocated since `before` under `name`. */
	public function stop(name:String, before:AllocationMeter.AllocationSnapshot):Void
		record(name, before, AllocationMeter.sample());

	function record(name:String, before:AllocationMeter.AllocationSnapshot,
			after:AllocationMeter.AllocationSnapshot):Void {
		if (!bytes.exists(name))
			order.push(name);
		bytes.set(name, (bytes.exists(name) ? bytes.get(name) : 0.0) + after.bytes - before.bytes);
		counts.set(name, (counts.exists(name) ? counts.get(name) : 0.0) + after.count - before.count);
	}

	/** One entry per pass: name, bytes, objects. */
	public function entries():Array<IrPassAllocation> {
		var result:Array<IrPassAllocation> = [];
		for (name in order) {
			var passBytes = bytes.get(name), passCount = counts.get(name);
			result.push({
				name: name,
				bytes: passBytes == null ? 0.0 : passBytes,
				count: passCount == null ? 0.0 : passCount
			});
		}
		return result;
	}
}
