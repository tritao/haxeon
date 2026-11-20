package compiler.core;

/**
 * Phase marks for finding what sets the compiler's peak memory (`scripts/peak-census.sh`), a no-op unless asked for.
 *
 * With `HAXEON_PEAK_MARKS` set, each mark prints `mark NAME SECONDS` to stderr, for a timeline of resident memory by phase.
 * With `HAXEON_PEAK_CENSUS` naming a mark (or `all`), that mark also runs the runtime's heap census (`hl_gc_census`, which
 * collects first unless `HL_GC_CENSUS_NOGC` is set): live bytes by type, owner and root path, and pages by size class.
 */
class PeakProbe {
	@:processWide("a diagnostic switch read once from the environment")
	static var state = -1;
	@:processWide("a diagnostic switch read once from the environment")
	static var censusAt:Null<String> = null;

	/** Whether marks print: a caller that builds a mark's name checks this first. */
	public static function on():Bool {
		if (state < 0) {
			censusAt = Sys.getEnv("HAXEON_PEAK_CENSUS");
			state = Sys.getEnv("HAXEON_PEAK_MARKS") != null || censusAt != null ? 1 : 0;
		}
		return state == 1;
	}

	public static function mark(name:String):Void {
		if (!on())
			return;
		Sys.stderr().writeString("mark " + name + " " + Std.string(Sys.time()) + "\n");
		if (censusAt == name || censusAt == "all")
			census(name);
	}

	static function census(name:String):Void {
		#if (haxeon && hl)
		var text = haxe.io.Bytes.ofString(name);
		var label = haxe.io.Bytes.alloc(text.length + 1);
		label.blit(0, text, 0, text.length);
		label.set(text.length, 0);
		runtimeCensus(label.getData());
		#end
	}

	#if (haxeon && hl)
	@:hlNative("std", "gc_census") static function runtimeCensus(label:hl.Bytes):Void {}
	#end
}
