package build;

/** Deterministic presentation of wall-clock measurements for one build invocation. */
class BuildTimings {
	final entries:Array<{name:String, milliseconds:Float}>;

	public function new() {
		entries = [];
	}

	public function add(name:String, milliseconds:Float):Void
		entries.push({name: name, milliseconds: milliseconds});

	public function addElapsed(name:String, started:Float):Void
		add(name, Sys.time() * 1000.0 - started);

	public function toString():String {
		var output = new StringBuf();
		output.add("Timings:\n");
		for (entry in entries)
			output.add('  ${entry.name}: ${format(entry.milliseconds)} ms\n');
		return output.toString();
	}

	static function format(milliseconds:Float):String
		return Std.string(Math.round(milliseconds * 100) / 100);
}
