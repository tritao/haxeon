package compiler.tools;

import sys.io.File;

/**
 * A compiler worker's memory after a build, for finding what a warm session keeps (see docs/COMPILER_MEMORY.md): with HAXEON_COMPILER_MEMORY_LOG=<file> every build
 * ends with a full collection and one line saying how much heap the collector held before it, how much stayed alive, and the process's
 * resident size. HAXEON_COMPILER_HEAP_DUMP=<file> also writes the live heap (HashLink's memory dump, as large as the heap) after the builds
 * named by HAXEON_COMPILER_HEAP_DUMP_ON, to <file>.<last word of the output name>.
 */
class CompilerMemoryLog {
	public static function record(label:String, ?session:CompilerSession):Void {
		#if hl
		var path = Sys.getEnv("HAXEON_COMPILER_MEMORY_LOG");
		if (path == null)
			return;
		var before = hl.Gc.stats(),
			residentBefore = residentGb(),
			startedAt = Sys.time();
		hl.Gc.major();
		var collectedMs = (Sys.time() - startedAt) * 1000.0,
			after = hl.Gc.stats();
		var line = '$label heap-before=${gb(before.currentMemory)} live-after-major=${gb(after.currentMemory)} resident-before=$residentBefore resident-after=${residentGb()} '
			+ 'allocated-total=${gb(after.totalAllocated)} major-ms=${Std.int(collectedMs)}';
		if (session != null)
			line += ' modules=' + moduleIdentities(session) + '\n';
		var out = File.append(path);
		out.writeString(line);
		out.close();
		// HAXEON_COMPILER_HEAP_DUMP=<file> with HAXEON_COMPILER_HEAP_DUMP_ON=<comma-separated suffixes>: the builds whose output ends in one.
		var dump = Sys.getEnv("HAXEON_COMPILER_HEAP_DUMP"),
			on = Sys.getEnv("HAXEON_COMPILER_HEAP_DUMP_ON");
		if (dump != null && label != null)
			for (suffix in (on == null ? [""] : on.split(",")))
				if (StringTools.endsWith(label, suffix)) {
					hl.Gc.dumpMemory(dump + "." + label.substr(label.lastIndexOf("-") + 1));
					break;
				}
		#end
	}

	/** Whether the places that keep a module refer to one module object: the cached result, the reuse snapshot, the encoded-bytes cache. */
	static function moduleIdentities(session:CompilerSession):String {
		#if hl
		@:privateAccess {
			var compiler = session.compiler;
			if (compiler == null)
				return "no-compiler";
			var result = compiler.cachedCompileResult == null ? null : compiler.cachedCompileResult.module,
				snapshot = compiler.pipelineSnapshot == null || compiler.pipelineSnapshot.backend == null ? null : compiler.pipelineSnapshot.backend.assembly.module,
				encoded = session.encodedModule == null ? null : session.encodedModule.code;
			return 'result==snapshot:${result == snapshot} result==encoded:${result == encoded} snapshot==encoded:${snapshot == encoded} result:${result != null} snapshot:${snapshot != null} encoded:${encoded != null}';
		}
		#end
		return "";
	}

	static function gb(bytes:Float):String
		return Std.string(Math.round(bytes / 1073741.824) / 1000.0);

	static function residentGb():String {
		try {
			var input = File.read("/proc/self/statm"),
				text = input.readAll().toString();
			input.close();
			var fields = StringTools.trim(text).split(" ");
			return Std.string(Math.round(Std.parseFloat(fields[1]) * 4096.0 / 1073741.824) / 1000.0);
		} catch (_:Dynamic)
			return "?";
	}
}
