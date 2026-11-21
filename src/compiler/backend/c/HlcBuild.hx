package compiler.backend.c;

import compiler.backend.c.HlcModule.HlcFile;
import compiler.core.InternalError;
import compiler.ffi.ProcessOutputCapture;
import sys.FileSystem;
import sys.io.File;

/**
 * Writes a C build's sources and, given a C compiler and SDK (`CompileOptions.cCompiler`, `cSdk`), compiles and links them
 * (docs/design/AOT_BACKEND.md). A file whose text did not change is not written again, and an object newer than its source and
 * the header is not compiled again, so an edit recompiles only the modules it changed.
 */
class HlcBuild {
	/** Writes `files` into `directory`; returns how many changed. Files of an earlier build that this one lacks are removed. */
	public static function write(files:Array<HlcFile>, directory:String):Int {
		FileSystem.createDirectory(directory);
		var changed = 0, kept:Map<String, Bool> = [];
		for (file in files) {
			var path = directory + "/" + file.path;
			kept.set(file.path, true);
			if (FileSystem.exists(path) && File.getContent(path) == file.content)
				continue;
			File.saveContent(path, file.content);
			changed++;
		}
		for (name in FileSystem.readDirectory(directory))
			if ((StringTools.endsWith(name, ".c") || StringTools.endsWith(name, ".h")) && !kept.exists(name))
				FileSystem.deleteFile(directory + "/" + name);
		return changed;
	}

	/**
	 * Compiles the C files of `directory` and the SDK's runtime support, and links the executable `output`. Returns how many it
	 * compiled. With `exactFrames` (a development build) the C compiler inlines no generated function into another, so stack
	 * traces are the JIT's frame for frame; otherwise it inlines as it sees fit and the stack capture restores the inlined frames
	 * from the DWARF inline records. Each kind has its own objects.
	 */
	public static function compile(files:Array<HlcFile>, directory:String, output:String, cCompiler:String, sdk:String,
			exactFrames:Bool):Int {
		var objects = directory + (exactFrames ? "/obj-development" : "/obj-release");
		FileSystem.createDirectory(objects);
		var header = directory + "/hlc.h", headerTime = modified(header);
		var sources = [for (file in files) if (StringTools.endsWith(file.path, ".c")) directory + "/" + file.path];
		sources.push(sdk + "/src/hlc_main.c");
		sources.push(sdk + "/src/hlc_stack.c");
		var outputs = [for (source in sources) objects + "/"
			+ haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(source)) + ".o"];
		// No sibling calls: a Haxe stack trace has the frame of every call, as the JIT's has, and a jump leaves no record to restore
		// it from. No cross-jumping, where the compiler has the flag (gcc; clang has not): identical calls of different Haxe lines
		// (throws, most often, also in inlined copies of one function) are not merged into one, which would keep one line and
		// lose the inlined frames of the others.
		var flags = [
			"-std=gnu11", "-O2", "-g", "-fwrapv", "-fno-strict-aliasing", "-fno-optimize-sibling-calls", "-w",
			'-I$directory', '-I$sdk/include'
		];
		if (exactFrames)
			flags.push("-DHLC_EXACT_FRAMES");
		// libhl is linked statically: its functions are referenced directly, not through a DLL's import table.
		if (Sys.systemName() == "Windows")
			flags.push("-DHL_IMPORT=extern");
		if (ProcessOutputCapture.capture(cCompiler, ["-fno-crossjumping", "--version"], 0).exitCode == 0)
			flags.push("-fno-crossjumping");
		// Objects made with other flags or another compiler are all made again.
		var stamp = objects + "/flags", command = [cCompiler].concat(flags).join(" ");
		var rebuild = !FileSystem.exists(stamp) || File.getContent(stamp) != command;
		var pending = [
			for (index in 0...sources.length)
				if (rebuild || !FileSystem.exists(outputs[index])
				|| modified(outputs[index]) <= Math.max(modified(sources[index]), headerTime)) index
		];
		var failures:Array<Null<String>> = [for (_ in pending) null];
		compiler.core.Parallel.forEach(pending.length, 8, function(item) {
			var index = pending[item];
			var result = ProcessOutputCapture.capture(cCompiler, flags.concat([
				"-c",
				sources[index],
				"-o",
				outputs[index]
			]),
				ProcessOutputCapture.defaultDiagnosticLimit);
			if (result.exitCode != 0)
				failures[item] = '${sources[index]}:\n${result.stderr}';
		});
		for (failure in failures)
			if (failure != null)
				throw new InternalError('C compilation failed: $failure');
		File.saveContent(stamp, command);
		// The whole VM library is linked: the loader resolves natives by name (`hlp_*`) in the executable itself, so nothing in the
		// generated code references them, and they must be exported.
		var link = ["-o", output].concat(outputs);
		if (Sys.systemName() == "Mac")
			link = link.concat([
				'-Wl,-force_load,$sdk/lib/libhl.a',
				'$sdk/lib/libffi.a',
				"-lm",
				"-lpthread",
				"-Wl,-export_dynamic"
			]);
		else if (Sys.systemName() == "Windows")
			// MinGW. The entry point is wmain; the main thread gets the 8 MB stack the other platforms give it.
			link = link.concat([
				"-Wl,--whole-archive",
				'$sdk/lib/libhl.a',
				"-Wl,--no-whole-archive",
				'$sdk/lib/libffi.a',
				"-municode",
				"-Wl,--stack,8388608",
				"-lws2_32",
				"-luser32",
				"-lwinmm",
				"-ldbghelp",
				"-lbcrypt",
				"-ladvapi32"
			]);
		else
			link = link.concat([
				"-Wl,--whole-archive",
				'$sdk/lib/libhl.a',
				"-Wl,--no-whole-archive",
				'$sdk/lib/libffi.a',
				"-lm",
				"-lpthread",
				"-ldl",
				"-Wl,--export-dynamic"
			]);
		var result = ProcessOutputCapture.capture(cCompiler, link, ProcessOutputCapture.defaultDiagnosticLimit);
		if (result.exitCode != 0)
			throw new InternalError('C link failed:\n${result.stderr}');
		return pending.length;
	}

	static function modified(path:String):Float
		return FileSystem.exists(path) ? FileSystem.stat(path).mtime.getTime() : 0.0;
}
