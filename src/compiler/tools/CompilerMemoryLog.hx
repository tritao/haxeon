package compiler.tools;

import compiler.compilation.BackendArtifact.BackendArtifacts;
import sys.io.File;

/**
 * A compiler worker's memory after a build, for finding what a warm session keeps (see docs/reports/2026-11-compiler-memory.md): with HAXEON_COMPILER_MEMORY_LOG=<file> every build
 * ends with a full collection and one line saying how much heap the collector held before it, how much stayed alive, and the process's
 * resident size. HAXEON_COMPILER_HEAP_DUMP=<file> also writes the live heap (HashLink's memory dump, as large as the heap) after the builds
 * numbered by HAXEON_COMPILER_HEAP_DUMP_ON (comma-separated, counted from 1 in the worker; every build without it), to <file>.<number>.
 * A live session builds one output again and again, so builds are told apart by their number, not by their output's name.
 */
class CompilerMemoryLog {
	/** The builds this worker has recorded. */
	@:processWide("numbers the worker's builds for the opt-in heap dumps, so it counts across compiles on purpose")
	static var builds = 0;

	public static function record(label:String, ?session:CompilerSession):Void {
		#if hl
		var path = Sys.getEnv("HAXEON_COMPILER_MEMORY_LOG");
		if (path == null)
			return;
		var build = ++builds;
		var before = hl.Gc.stats(),
			residentBefore = residentGb(),
			startedAt = Sys.time();
		hl.Gc.major();
		var collectedMs = (Sys.time() - startedAt) * 1000.0,
			after = hl.Gc.stats();
		var line =
			'$label heap-before=${gb(before.currentMemory)} live-after-major=${gb(after.currentMemory)} resident-before=$residentBefore resident-after=${residentGb()} '
			+ 'allocated-total=${gb(after.totalAllocated)} major-ms=${Std.int(collectedMs)}';
		if (session != null)
			line += ' modules=' + moduleIdentities(session);
		line += ' build=$build\n';
		var out = File.append(path);
		out.writeString(line);
		out.close();
		var dump = Sys.getEnv("HAXEON_COMPILER_HEAP_DUMP"),
			on = Sys.getEnv("HAXEON_COMPILER_HEAP_DUMP_ON");
		if (dump != null && (on == null || on.split(",").contains(Std.string(build))))
			hl.Gc.dumpMemory(dump + "." + build);
		#end
	}

	/** Whether the places that keep a module refer to one module's bytes: the cached result, the reuse snapshot, the encoded-bytes cache. */
	static function moduleIdentities(session:CompilerSession):String {
		#if hl
		@:privateAccess {
			var compiler = session.compiler;
			if (compiler == null)
				return "no-compiler";
			var cached = compiler.cachedCompileResult,
				pipeline = compiler.state.pipelineSnapshot,
				known = session.encodedModule;
			var backend = pipeline == null ? null : pipeline.backend;
			var result = cached == null ? null : BackendArtifacts.hashLink(cached.artifact).sections,
				snapshot = backend == null ? null : BackendArtifacts.hashLink(backend.artifact).sections,
				encoded = known == null ? null : known.bytes;
			return 'result==snapshot:${result == snapshot} result==encoded:${result == encoded} snapshot==encoded:${snapshot == encoded} result:${result != null} snapshot:${snapshot != null} encoded:${encoded != null}';
		}
		#else
		return "";
		#end
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
