package haxeon.test;

/** One named part of a test program. `weight` is roughly how long it takes relative to the others, to balance the shards. */
typedef TestGroup = {
	final name:String;
	final run:Void->Void;
	final ?weight:Float;
}

/**
 * Splits a test program into shards that run as separate processes, so that a suite made of many independent groups takes as
 * long as its slowest shard instead of the sum of its groups, and lets one run pick the groups it needs.
 *
 * The program lists its groups and calls `run`. Its arguments:
 * - `--shard I/N` (I from 1): only the groups that shard owns. Which shard owns a group is worked out from the groups
 *   themselves, the same way in every process, so every group belongs to exactly one shard for any N: a shard count in a
 *   workspace file cannot leave a group out.
 * - `--only A,B*`: only the named groups; `*` matches any run of characters. A pattern that matches no group is an error, so
 *   a typo does not pass by running nothing.
 * - `--list`: print the group names (after `--shard`/`--only`) and run nothing.
 * - `--keep-going`: run every selected group even when one fails, then report all the failures together.
 * With no arguments every group runs, as before. The groups must not depend on each other, since shards run in separate
 * processes and `--only` runs a group alone.
 */
class Shards {
	/**
	 * Runs this process's groups, in the order they are listed, and prints how long each took. Returns true when that was every
	 * group (no shard or selection given), so the caller can report the whole suite as passed. Throws when a group fails.
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
		var only = args.indexOf("--only"), selected = false;
		if (only >= 0) {
			if (only + 1 >= args.length || StringTools.startsWith(args[only + 1], "--"))
				throw 'Expected "--only NAME[,NAME...]"';
			running = select(groups, running, args[only + 1].split(","));
			selected = true;
		}
		if (args.indexOf("--list") >= 0) {
			for (group in running)
				Sys.println(group.name);
			return false;
		}
		if (count > 1)
			Sys.println('shard $shard/$count: ${running.length} of ${groups.length} groups');
		else if (selected)
			Sys.println('selected ${running.length} of ${groups.length} groups');
		var keepGoing = args.indexOf("--keep-going") >= 0, failures:Array<String> = [];
		for (group in running) {
			var groupStarted = Sys.time();
			if (!keepGoing)
				group.run();
			else
				try
					group.run()
				catch (error:Dynamic) {
					failures.push(group.name);
					Sys.println('  FAIL ${group.name}: ${Std.string(error)}');
					continue;
				}
			Sys.println('  ${group.name}: ${round(Sys.time() - groupStarted)} s');
		}
		if (failures.length > 0)
			throw '${failures.length} of ${running.length} groups failed: ${failures.join(", ")}';
		if (count > 1)
			Sys.println('shard $shard/$count passed (${running.length} groups, ${round(Sys.time() - started)} s)');
		else if (selected)
			Sys.println('selected groups passed (${running.length}, ${round(Sys.time() - started)} s)');
		return count == 1 && !selected;
	}

	/** The groups of `running`, in order, that some pattern names. Every pattern must name at least one of `groups`. */
	public static function select(groups:Array<TestGroup>, running:Array<TestGroup>, patterns:Array<String>):Array<TestGroup> {
		for (pattern in patterns) {
			if (pattern == "")
				throw "An empty --only pattern";
			var matched = false;
			for (group in groups)
				if (matches(pattern, group.name))
					matched = true;
			if (!matched)
				throw 'No test group matches "$pattern"';
		}
		return [
			for (group in running)
				if (Lambda.exists(patterns, pattern -> matches(pattern, group.name))) group
		];
	}

	/** `name` against a pattern where `*` matches any run of characters (none included). */
	public static function matches(pattern:String, name:String):Bool {
		var parts = pattern.split("*");
		if (parts.length == 1)
			return pattern == name;
		if (!StringTools.startsWith(name, parts[0]))
			return false;
		var at = parts[0].length;
		for (index in 1...parts.length - 1) {
			var found = name.indexOf(parts[index], at);
			if (found < 0)
				return false;
			at = found + parts[index].length;
		}
		var last = parts[parts.length - 1];
		return name.length - last.length >= at && StringTools.endsWith(name, last);
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
