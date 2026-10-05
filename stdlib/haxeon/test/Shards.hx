package haxeon.test;

/** One named part of a test program. `weight` is roughly how long it takes relative to the others, to balance the shards. */
typedef TestGroup = {
	final name:String;
	final run:Void->Void;
	final ?weight:Float;
}

/**
 * Splits a test program into shards that run as separate processes, so that a suite made of many independent groups takes as
 * long as its slowest shard instead of the sum of its groups.
 *
 * The program lists its groups and calls `run`. Started with `--shard I/N` (I from 1) it runs only the groups that shard owns;
 * started with no arguments it runs them all, as before. Which shard owns a group is worked out from the groups themselves,
 * the same way in every process, so every group belongs to exactly one shard for any N: a shard count in a workspace file
 * cannot leave a group out. The groups must not depend on each other, since shards run in separate processes.
 */
class Shards {
	/**
	 * Runs this process's groups, in the order they are listed, and prints how long each took. Returns true when that was every
	 * group (no shard given), so the caller can report the whole suite as passed.
	 */
	public static function run(groups:Array<TestGroup>, ?arguments:Array<String>):Bool {
		var args = arguments == null ? Sys.args() : arguments, shard = 1, count = 1, position = args.indexOf("--shard");
		if (position >= 0) {
			var parsed = parse(position + 1 < args.length ? args[position + 1] : "");
			shard = parsed.shard;
			count = parsed.count;
		}
		var owned = assignment(groups, shard, count), started = Sys.time();
		var running = [for (group in groups) if (owned.indexOf(group.name) >= 0) group];
		if (count > 1)
			Sys.println('shard $shard/$count: ${running.length} of ${groups.length} groups');
		for (group in running) {
			var groupStarted = Sys.time();
			group.run();
			Sys.println('  ${group.name}: ${round(Sys.time() - groupStarted)} s');
		}
		if (count > 1)
			Sys.println('shard $shard/$count passed (${running.length} groups, ${round(Sys.time() - started)} s)');
		return count == 1;
	}

	/** The names of the groups shard `shard` (1 to `count`) runs. Heavier groups are placed first, each on the lightest shard so far. */
	public static function assignment(groups:Array<TestGroup>, shard:Int, count:Int):Array<String> {
		if (count < 1 || shard < 1 || shard > count)
			throw 'Shard $shard of $count does not exist';
		var seen = new Map<String, Bool>();
		for (group in groups) {
			if (seen.exists(group.name))
				throw 'Two test groups are named "${group.name}"';
			seen.set(group.name, true);
		}
		var order = [for (index in 0...groups.length) index];
		order.sort((a, b) -> {
			var difference = weightOf(groups[b]) - weightOf(groups[a]);
			return difference > 0 ? 1 : (difference < 0 ? -1 : a - b);
		});
		var loads = [for (_ in 0...count) 0.0], owner:Array<Int> = [for (_ in groups) 0];
		for (index in order) {
			var lightest = 0;
			for (candidate in 1...count)
				if (loads[candidate] < loads[lightest])
					lightest = candidate;
			loads[lightest] += weightOf(groups[index]);
			owner[index] = lightest + 1;
		}
		return [for (index in 0...groups.length) if (owner[index] == shard) groups[index].name];
	}

	static function weightOf(group:TestGroup):Float
		return group.weight == null ? 1.0 : group.weight;

	static function parse(text:String):{shard:Int, count:Int} {
		var parts = text.split("/"), shard = parts.length == 2 ? Std.parseInt(parts[0]) : null, count = parts.length == 2 ? Std.parseInt(parts[1]) : null;
		if (shard == null || count == null || count < 1 || shard < 1 || shard > count)
			throw 'Expected "--shard I/N" with 1 <= I <= N, got "$text"';
		return {shard: shard, count: count};
	}

	static function round(seconds:Float):String
		return Std.string(Math.round(seconds * 10) / 10);
}
