package compiler.backend.c;

import compiler.backend.c.HlcModule.HlcFile;
import compiler.core.InternalError;
import compiler.core.UsageError;
import compiler.ffi.ProcessOutputCapture;
import sys.FileSystem;
import sys.io.File;

/**
 * Writes a C build's sources and, given an SDK (`CompileOptions.cSdk`), compiles and links them with a toolchain (`toolchain`)
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
	 * The toolchain that builds against `sdk`: `requested` (`--toolchain`: `gcc`, `clang`, `clang-cl`, `cl`, or a path to one),
	 * or the default for the target the SDK was built for (its `target` file, OS-ARCH-ABI as `build.Target` spells it): `cc` for
	 * Linux and macOS, `clang-cl` for Windows with MSVC's ABI, MinGW's gcc for Windows with GNU's. A toolchain is a compiler,
	 * its linker, flags, debug format and C runtime together; one of the other ABI's is a usage error.
	 */
	public static function toolchain(sdk:String, requested:Null<String>):String {
		var target = sdkTarget(sdk), msvc = target.abi == "msvc";
		var valid = msvc ? "clang-cl, cl, or a path to one" : "gcc, clang, or a path to one";
		if (requested == null && msvc)
			return "clang-cl";
		if (requested == null && target.os != "windows")
			return "cc";
		// MinGW's gcc: `gcc` in its own environment on Windows, else the cross compiler of the SDK's architecture.
		if (requested == null)
			return Sys.systemName() == "Windows"
				? "gcc" : (target.arch == "arm64" ? "aarch64" : "x86_64") + "-w64-mingw32-gcc";
		var driver = driverOf(requested);
		if (driver == null)
			throw new UsageError('Unknown --toolchain "$requested" for the hlc SDK\'s target ${target.name}. Valid: $valid');
		if ((driver != Gnu) != msvc)
			throw new UsageError('--toolchain "$requested" does not build for the hlc SDK\'s target ${target.name}. Valid: $valid');
		return requested;
	}

	/** The target the SDK at `sdk` was built for, from its `target` file (CMakeLists.txt writes it). */
	static function sdkTarget(sdk:String):{name:String, os:String, arch:String, abi:String} {
		var path = sdk + "/target";
		if (!FileSystem.exists(path))
			throw new UsageError('No hlc SDK at $sdk: $path is missing (the native build makes it, target haxeon-hlc-sdk)');
		var name = StringTools.trim(File.getContent(path)), parts = name.split("-");
		return {
			name: name,
			os: parts[0],
			arch: parts.length > 1 ? parts[1] : "",
			abi: parts.length > 2 ? parts[2] : parts[0] == "macos" ? "darwin" : ""
		};
	}

	/**
	 * Compiles the C files of `directory` and the SDK's runtime support, and links the executable `output`. Returns how many it
	 * compiled. With `exactFrames` (a development build) the C compiler inlines no generated function into another, so stack
	 * traces are the JIT's frame for frame; otherwise it inlines as it sees fit and the stack capture restores the inlined frames
	 * from the debug information's inline records. Each kind has its own objects.
	 */
	public static function compile(files:Array<HlcFile>, directory:String, output:String, toolchain:String, sdk:String,
			exactFrames:Bool):Int {
		var driver = driverOf(toolchain), os = sdkTarget(sdk).os;
		var objects = directory + (exactFrames ? "/obj-development" : "/obj-release");
		FileSystem.createDirectory(objects);
		var header = directory + "/hlc.h", headerTime = modified(header);
		var sources = [for (file in files) if (StringTools.endsWith(file.path, ".c")) directory + "/" + file.path];
		sources.push(sdk + "/src/hlc_main.c");
		sources.push(sdk + "/src/hlc_stack.c");
		var outputs = [for (source in sources) objects + "/"
			+ haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(source)) + (driver == Gnu ? ".o" : ".obj")];
		// cl takes `-I` as gcc does.
		var flags = (driver == Gnu ? gnuFlags(toolchain, os, exactFrames) : msvcFlags(driver, exactFrames)).concat([
			'-I$directory',
			'-I$sdk/include'
		]);
		// Objects made with other flags or another compiler are all made again.
		var stamp = objects + "/flags", command = [toolchain].concat(flags).join(" ");
		var rebuild = !FileSystem.exists(stamp) || File.getContent(stamp) != command;
		var pending = [
			for (index in 0...sources.length)
				if (rebuild || !FileSystem.exists(outputs[index])
				|| modified(outputs[index]) <= Math.max(modified(sources[index]), headerTime)) index
		];
		// The largest first: the build's time is the slowest file's, so it starts at once.
		var sizes = [for (index in pending) index => FileSystem.stat(sources[index]).size];
		pending.sort((a, b) -> sizes.get(b) - sizes.get(a));
		var failures:Array<Null<String>> = [for (_ in pending) null];
		compiler.core.Parallel.forEach(pending.length, processorCount(), function(item) {
			var index = pending[item];
			var object = driver == Gnu ? ["-o", outputs[index]] : ["/Fo" + outputs[index]];
			var result = ProcessOutputCapture.capture(toolchain, flags.concat(["-c", sources[index]]).concat(object),
				ProcessOutputCapture.defaultDiagnosticLimit);
			if (result.exitCode != 0)
				failures[item] = '${sources[index]}:\n${result.stderr}${result.stdout}';
		});
		for (failure in failures)
			if (failure != null)
				throw new InternalError('C compilation failed: $failure');
		File.saveContent(stamp, command);
		var link = driver == Gnu ? gnuLink(output, outputs, sdk, os, exactFrames) : msvcLink(output, outputs, sdk);
		var result = ProcessOutputCapture.capture(toolchain, link, ProcessOutputCapture.defaultDiagnosticLimit);
		if (result.exitCode != 0)
			throw new InternalError('C link failed:\n${result.stderr}${driver == Gnu ? "" : result.stdout}');
		if (driver == Gnu && !exactFrames && os == "linux")
			stripSymbols(toolchain, output);
		return pending.length;
	}

	/**
	 * Which command line a toolchain takes, by its compiler's name: MSVC's (`cl`, and `clang-cl`, LLVM's compiler with MSVC's
	 * command line and ABI), or GCC's (`cc`, gcc and clang, versioned or prefixed as `gcc-14` or `x86_64-w64-mingw32-gcc`);
	 * null for any other.
	 */
	static function driverOf(toolchain:String):Null<HlcDriver> {
		var name = haxe.io.Path.withoutDirectory(toolchain).toLowerCase();
		if (StringTools.endsWith(name, ".exe"))
			name = name.substr(0, name.length - 4);
		if (name == "cl")
			return Msvc;
		if (StringTools.startsWith(name, "clang-cl"))
			return ClangCl;
		return name == "cc" || name.indexOf("gcc") >= 0 || name.indexOf("clang") >= 0 ? Gnu : null;
	}

	/**
	 * gcc's and clang's flags. No sibling calls: a Haxe stack trace has the frame of every call, as the JIT's has, and a jump
	 * leaves no record to restore it from. No cross-jumping, where the compiler has the flag (gcc; clang has not): identical
	 * calls of different Haxe lines (throws, most often, also in inlined copies of one function) are not merged into one, which
	 * would keep one line and lose the inlined frames of the others.
	 * Debug information is the line tables and the inline records the stack traces read (`-g1`), not the variables and types a
	 * debugger shows, which are most of its compile time. A development build is not optimized, so it builds quickly.
	 * The generated functions are not exported: the loader finds natives in libhl by name, never a generated function, and an
	 * exported name costs the dynamic symbol table and string table an entry each.
	 */
	static function gnuFlags(toolchain:String, os:String, exactFrames:Bool):Array<String> {
		var flags = [
			"-std=gnu11", exactFrames ? "-O0" : "-O2", "-g1", "-fwrapv", "-fno-strict-aliasing",
			"-fno-optimize-sibling-calls", "-fvisibility=hidden", "-w"
		];
		if (exactFrames)
			flags.push("-DHLC_EXACT_FRAMES");
		// libhl is linked statically: its functions are referenced directly, not through a DLL's import table.
		if (os == "windows")
			flags.push("-DHL_IMPORT=extern");
		if (ProcessOutputCapture.capture(toolchain, ["-fno-crossjumping", "--version"], 0).exitCode == 0)
			flags.push("-fno-crossjumping");
		return flags;
	}

	/**
	 * cl's and clang-cl's flags, as `gnuFlags`. The debug information is CodeView in each object (`/Z7`, so parallel compiles
	 * share no PDB), which the link gathers into the PDB the stack traces read through DbgHelp; clang-cl keeps only its line
	 * tables and inline sites. The C runtime is the DLL one (`/MD`), as the SDK's libhl.lib is built with. clang-cl takes gcc's
	 * flags for wrapping arithmetic and no sibling calls; cl has neither, and relies on MSVC not using signed overflow and on a
	 * release build's tail calls being rare (docs/design/AOT_BACKEND.md).
	 */
	static function msvcFlags(driver:HlcDriver, exactFrames:Bool):Array<String> {
		var flags = ["/nologo", "/std:c11", exactFrames ? "/Od" : "/O2", "/Z7", "/MD", "/w", "/DHL_IMPORT=extern"];
		if (exactFrames)
			flags.push("/DHLC_EXACT_FRAMES");
		if (driver == ClangCl)
			flags = flags.concat([
				"-gline-tables-only",
				"/clang:-fwrapv",
				"/clang:-fno-strict-aliasing",
				"/clang:-fno-optimize-sibling-calls"
			]);
		return flags;
	}

	/** The link with gcc's driver: the whole VM library, as the loader resolves natives by name (`hlp_*`) in the executable. */
	static function gnuLink(output:String, objects:Array<String>, sdk:String, os:String,
			exactFrames:Bool):Array<String> {
		var link = ["-o", output].concat(objects);
		if (os == "macos")
			return link.concat([
				'-Wl,-force_load,$sdk/lib/libhl.a',
				'$sdk/lib/libffi.a',
				"-lm",
				"-lpthread",
				"-Wl,-export_dynamic"
			]);
		if (os == "windows")
			// MinGW. The entry point is wmain; the main thread gets the 8 MB stack the other platforms give it.
			return link.concat([
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
		// A release build's DWARF is compressed with zlib (SHF_COMPRESSED), which the stack traces inflate at the first one and gdb,
		// perf and addr2line read as it is.
		if (!exactFrames)
			link.push("-Wl,--compress-debug-sections=zlib");
		return link;
	}

	/**
	 * The link with cl's driver: `output`.exe and its PDB, `output`.pdb, beside it. The whole VM library is linked, its natives
	 * exported (libhl's objects declare them so), and the loader finds them in the executable by name. The PDB is made in both
	 * build modes, as the stack traces name frames from it. Identical functions are not folded (`/OPT:NOICF`): each generated
	 * function keeps its own address and so its own name and lines; and no incremental link puts jump thunks where the stack
	 * capture expects the functions. The entry point is wmain, and the main thread gets the 8 MB
	 * stack the other platforms give it.
	 */
	static function msvcLink(output:String, objects:Array<String>, sdk:String):Array<String> {
		return ["/nologo", '/Fe$output'].concat(objects).concat([
			"/link",
			"/DEBUG",
			"/INCREMENTAL:NO",
			"/OPT:REF",
			"/OPT:NOICF",
			"/STACK:8388608",
			'/WHOLEARCHIVE:$sdk/lib/libhl.lib',
			'$sdk/lib/libhl.lib',
			'$sdk/lib/libffi.lib',
			"ws2_32.lib",
			"user32.lib",
			"winmm.lib",
			"dbghelp.lib",
			"dxguid.lib",
			"bcrypt.lib",
			"advapi32.lib"
		]);
	}

	/**
	 * Drops a release executable's symbol table and `.debug_aranges`: the stack traces name frames from the module image and read
	 * the DWARF line tables and inline records, which stay, as do the dynamic symbols the loader resolves natives by. gdb and
	 * addr2line find functions from the DWARF. A development build keeps everything.
	 */
	static function stripSymbols(toolchain:String, output:String):Void {
		var found = ProcessOutputCapture.capture(toolchain, ["-print-prog-name=objcopy"], 0);
		var objcopy = found.exitCode == 0
			&& StringTools.trim(found.stdout) != "" ? StringTools.trim(found.stdout) : "objcopy";
		var result = ProcessOutputCapture.capture(objcopy, [
			"--strip-all",
			"--keep-section=!.debug_aranges",
			"--keep-section=.debug_*",
			output
		],
			ProcessOutputCapture.defaultDiagnosticLimit);
		if (result.exitCode != 0)
			throw new InternalError('Stripping the symbol table of $output failed:\n${result.stderr}');
	}

	/** The processors this process may run on, each a C compile at a time. */
	static function processorCount():Int {
		var windows = Sys.getEnv("NUMBER_OF_PROCESSORS");
		if (windows != null && Std.parseInt(windows) != null)
			return Std.parseInt(windows);
		for (command in [["nproc"], ["sysctl", "-n", "hw.ncpu"]]) {
			var result = try ProcessOutputCapture.capture(command[0], command.slice(1), 0) catch (_:Dynamic) null;
			var count = result == null || result.exitCode != 0 ? null : Std.parseInt(StringTools.trim(result.stdout));
			if (count != null && count > 0)
				return count;
		}
		return 4;
	}

	static function modified(path:String):Float
		return FileSystem.exists(path) ? FileSystem.stat(path).mtime.getTime() : 0.0;
}

/** The command line a C compiler takes (`HlcBuild.driverOf`). */
enum HlcDriver {
	Gnu;
	Msvc;
	ClangCl;
}
