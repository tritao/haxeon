package compiler.core;

/** One IR pass's time and allocation in one compile. */
typedef IrPassCost = {
	final name:String;
	final milliseconds:Float;
	final bytes:Float;
	final count:Float;

	/** Functions whose blocks or body the pass read (`IrFunction.census`). */
	final read:Int;

	/** Functions the pass made: a new object for one it changed, or one it added. */
	final made:Int;

	/** Functions of its input the pass did not hand on: replaced by one it made, or removed. */
	final dropped:Int;
}

/** Where a pass started: the time and the allocation counters. */
typedef IrPassStart = {
	final time:Float;
	final allocation:AllocationMeter.AllocationSnapshot;
}

/**
 * Time and allocation of each IR pass in one compile, in the order the passes first ran, for the driver's timings line. A pass that runs more
 * than once (value phi scalarization runs between other passes) is summed under one name. A pass costs two meter samples: `start` and
 * `stop`, called by the stages `compiler.ir.IrPipeline` meters. Each compile's pipeline has its own (`IrPipelineContext.meter`).
 */
class IrPassMeter {
	final order:Array<String> = [];
	final milliseconds:Map<String, Float> = [];
	final bytes:Map<String, Float> = [];
	final counts:Map<String, Float> = [];
	final reads:Map<String, Int> = [];
	final made:Map<String, Int> = [];
	final dropped:Map<String, Int> = [];

	public function new() {}

	/** The sample `stop` measures from. */
	public function start():IrPassStart
		return {time: haxe.Timer.stamp(), allocation: AllocationMeter.sample()};

	/** Records the time taken and what was allocated since `before` under `name`. */
	public function stop(name:String, before:IrPassStart):Void {
		record(name, before, AllocationMeter.sample(), haxe.Timer.stamp());
		if (PeakProbe.on())
			PeakProbe.mark("pass-" + name);
	}

	function record(name:String, before:IrPassStart, after:AllocationMeter.AllocationSnapshot, time:Float):Void {
		if (!bytes.exists(name))
			order.push(name);
		milliseconds.set(name,
			(milliseconds.exists(name) ? milliseconds.get(name) : 0.0) + (time - before.time) * 1000);
		bytes.set(name, (bytes.exists(name) ? bytes.get(name) : 0.0) + after.bytes - before.allocation.bytes);
		counts.set(name, (counts.exists(name) ? counts.get(name) : 0.0) + after.count - before.allocation.count);
	}

	/** Records, under `name`, how many functions a pass read, made and dropped (`compiler.ir.IrStage.IrStageHooks.census`). */
	public function functions(name:String, read:Int, madeCount:Int, droppedCount:Int):Void {
		reads.set(name, (reads.exists(name) ? reads.get(name) : 0) + read);
		made.set(name, (made.exists(name) ? made.get(name) : 0) + madeCount);
		dropped.set(name, (dropped.exists(name) ? dropped.get(name) : 0) + droppedCount);
	}

	/** One entry per pass: name, milliseconds, bytes, objects. */
	public function entries():Array<IrPassCost> {
		var result:Array<IrPassCost> = [];
		for (name in order) {
			var passBytes = bytes.get(name),
				passCount = counts.get(name),
				passTime = milliseconds.get(name),
				passReads = reads.get(name),
				passMade = made.get(name),
				passDropped = dropped.get(name);
			result.push({
				name: name,
				milliseconds: passTime == null ? 0.0 : passTime,
				bytes: passBytes == null ? 0.0 : passBytes,
				count: passCount == null ? 0.0 : passCount,
				read: passReads == null ? 0 : passReads,
				made: passMade == null ? 0 : passMade,
				dropped: passDropped == null ? 0 : passDropped
			});
		}
		return result;
	}
}
