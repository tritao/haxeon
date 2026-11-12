package compiler.ir;

import compiler.ir.Ir;

/**
 * HAXEON_REACHABILITY_REPORT=<file>: appends, for the program at a named point of the pipeline, the counts of today's walk against the
 * type-aware walk (`IrTypeAwareWalk.compare`). The step 1 diagnostic of `docs/REACHABILITY_WALK.md`: it changes nothing and is off unless the
 * variable is set. The roots are the entry and every `@:keep` / `@:expose` function.
 */
class IrReachabilityReport {
	public static function enabled():Bool {
		var path = Sys.getEnv("HAXEON_REACHABILITY_REPORT");
		return path != null && path != "";
	}

	public static function report(point:String, program:IrProgram):Void {
		var path = Sys.getEnv("HAXEON_REACHABILITY_REPORT");
		if (path == null || path == "")
			return;
		var entries = [program.entryPoint];
		for (fn in program.functions)
			if (fn.retention != Reachable)
				entries.push(fn.name);
		var lines = IrTypeAwareWalk.compare(program, {functions: entries, types: []});
		var text = point + ", entry " + program.entryPoint + " (" + entries.length + " roots)\n  " + lines.join("\n  ") + "\n";
		sys.io.File.saveContent(path, (sys.FileSystem.exists(path) ? sys.io.File.getContent(path) : "") + text);
	}
}
