package compiler.tools;

/**
 * A diagnostic for where a build allocates. With HAXEON_COMPILER_ALLOC_CENSUS=<file> the worker counts every allocation by type while a
 * build runs and samples the call stack once per HAXEON_COMPILER_ALLOC_CENSUS_BYTES allocated bytes (default 1 MiB), then writes the
 * runtime's census (`gc_census_dump`: counts and bytes by type, sampled stacks with their bytes) to the file. Counting forces every
 * allocation through the ordinary allocator, so a build under it is slower and its times are not measurements. Read the file with
 * `scripts/alloc-sites.py`.
 */
class AllocationCensus {
	public static function begin():Bool {
		var file = Sys.getEnv("HAXEON_COMPILER_ALLOC_CENSUS");
		if (file == null || file == "")
			return false;
		var bytes = Sys.getEnv("HAXEON_COMPILER_ALLOC_CENSUS_BYTES"),
			every = bytes == null ? 1 << 20 : Std.parseInt(bytes);
		#if haxeon
		hl.Gc.censusStart(every == null ? 1 << 20 : every);
		#else
		Census.start(every);
		#end
		return true;
	}

	/** Stops the census begun by `begin` and writes it. */
	public static function end():Void {
		var file = Sys.getEnv("HAXEON_COMPILER_ALLOC_CENSUS");
		#if haxeon
		hl.Gc.censusStop();
		if (file != null)
			hl.Gc.censusDump(file);
		#else
		Census.stop();
		@:privateAccess Census.dump(file.toUtf8());
		#end
	}
}

#if !haxeon
/** The runtime's census primitives, bound directly: stock Haxe's hl.Gc has no census (the Haxeon stdlib's has). */
@:keep private extern class Census {
	@:hlNative("std", "gc_census_start") static function start(stackEveryBytes:Int):Void;
	@:hlNative("std", "gc_census_stop") static function stop():Void;
	@:hlNative("std", "gc_census_dump") static function dump(path:hl.Bytes):Void;
}
#end
