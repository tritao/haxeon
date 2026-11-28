package tools.dev;

import build.AotCompiler;
import build.HashLinkPath;
import build.execution.CompilerClient;
import build.execution.ProcessRunner;
import compiler.core.InternalError;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon dev aot [--toolchain=NAME] [--no-publish]`: builds the CLI and the compiler ahead of time, one executable
 * (`build.AotCompiler`), from this checkout and publishes it beside the VM with its stamp, which is what a release ships for its
 * platform. `--no-publish` leaves it in `out/aot`, so the haxeon command and the CLI keep running the compiler on the VM while a
 * test compiles with the executable. The executable built before (in `out/aot`, else the one published), current or not,
 * compiles `tools.CompilerExecutable` to C in release mode as every tool artifact (`HaxeonBuild.TOOL_BUILD_MODE`): it starts
 * at once and runs about twice as fast as the bytecode, and needs no bytecode build of the edited sources first. When there
 * is none, or it rejects the new sources (they use what it does not have yet), the checkout's compiler built to bytecode with
 * the pinned Haxe compiles them instead. A compiler built by its previous version is what self-hosting is; the self-compile
 * check keeps the two agreeing. `cmake/aot` builds the C with the SDK's CMake package (`haxeon_add_c_executable`).
 * `--toolchain` is the C compiler CMake builds with (`CMAKE_C_COMPILER`: `gcc`, `clang`, `clang-cl`, `cl`, or a path); without
 * it CMake chooses, except that an SDK built with MSVC is built with clang-cl, as the Windows release is. The C sources and
 * CMake's build stay in `out/aot`, so a rebuild after an edit compiles only the C files that changed, and a rebuild with the
 * sources unchanged reuses the C (its stamp is `haxeon-aot.c.sources`) and only checks CMake's build.
 */
class AotBuild {
	public static function run(arguments:Array<String>, home:String):Int {
		var toolchain:Null<String> = null, publish = true;
		for (argument in arguments)
			if (StringTools.startsWith(argument, "--toolchain="))
				toolchain = argument.substr("--toolchain=".length);
			else if (argument == "--no-publish")
				publish = false;
			else
				throw new InternalError('Usage: haxeon dev aot [--toolchain=NAME] [--no-publish] (unexpected "$argument")');
		home = Path.normalize(home);
		var nativeStatus = build.HaxeonBuild.buildNative(new build.BuildEnvironment(home, Path.join([home, "out"])));
		if (nativeStatus != 0)
			return nativeStatus;
		var sdk = build.HaxeonSdk.ofCheckout(home),
			directory = Path.join([home, "out", "aot"]),
			output = Path.join([directory, AotCompiler.NAME]),
			suffix = Sys.systemName() == "Windows" ? ".exe" : "",
			sourcesFile = Path.join([directory, "sources.txt"]),
			compilerSource = AotCompiler.sources(sdk);
		FileSystem.createDirectory(directory);
		var roots = ["src", "lib/haxeon-io", "stdlib"], sources = [];
		for (root in roots)
			collectSources(home, root, sources);
		sources.sort((left, right) -> left < right ? -1 : (left > right ? 1 : 0));
		File.saveContent(sourcesFile, sources.join("\n") + "\n");
		var digest = AotCompiler.sourcesDigest(sdk, compilerSource),
			generated = AotCompiler.stampOf('$output.c'),
			arguments = [
				'--build-mode=${build.HaxeonBuild.TOOL_BUILD_MODE}',
				"--entry=tools.CompilerExecutable",
				'--sources-file=$sourcesFile',
				"--target=hlc",
				'--output=$output'
			].concat([for (root in roots) '--root=$root']);
		var status = 0;
		if (!FileSystem.exists(generated) || StringTools.trim(File.getContent(generated)) != digest) {
			if (FileSystem.exists(generated))
				FileSystem.deleteFile(generated);
			var environment = CompilerClient.runtimeLibraryEnvironment(sdk), previous:Null<String> = null;
			for (candidate in [output + suffix, AotCompiler.executable(sdk)])
				if (previous == null && FileSystem.exists(candidate))
					previous = candidate;
			status = previous == null ? -1 : ProcessRunner.run(previous, arguments, home, environment);
			if (status != 0) {
				if (previous != null)
					Sys.stderr()
						.writeString('note: $previous did not compile these sources; compiling them with the bytecode compiler\n');
				var compiler = new ToolArtifacts(home).resolve({
					main: "compiler.tools.HaxeonCompiler",
					classPaths: [],
					defines: []
				});
				status = ProcessRunner.run(HashLinkPath.executable(sdk), [compiler].concat(arguments), home,
					environment);
				if (status != 0)
					return status;
			}
		}
		if (toolchain == null && msvcSdk(sdk))
			toolchain = "clang-cl";
		var binary = Path.join([directory, "build"]);
		status = ProcessRunner.run("cmake", [
			"-S",
			Path.join([home, "cmake", "aot"]),
			"-B",
			binary,
			"-G",
			"Ninja",
			'-DCMAKE_MAKE_PROGRAM=${build.native.NativeCMakeProvider.ninjaExecutable(sdk)}',
			'-DHaxeon_DIR=${build.HaxeonSdk.cmakeDirectory(sdk)}',
			'-DC_SOURCES=$output.c',
			'-DOUTPUT=$output'
		].concat(toolchain == null ? [] : ['-DCMAKE_C_COMPILER=$toolchain']), home, null);
		if (status == 0)
			status = ProcessRunner.run("cmake", ["--build", binary], home, null);
		if (status != 0)
			return status;
		// A source edited while it compiled would leave a stamp that the executable does not match.
		if (AotCompiler.sourcesDigest(sdk, compilerSource) != digest) {
			Sys.stderr().writeString("The compiler sources changed during the build; run it again\n");
			return 1;
		}
		File.saveContent(generated, digest + "\n");
		if (!publish) {
			Sys.println('Built $output$suffix');
			return 0;
		}
		// The stamp goes first and comes back last, so no moment pairs a new stamp with an old executable. A running worker keeps
		// the executable it started from: it is replaced by rename (cmake/haxeon-replace.cmake).
		var stamp = AotCompiler.stamp(sdk), published = AotCompiler.executable(sdk);
		if (FileSystem.exists(stamp))
			FileSystem.deleteFile(stamp);
		// With MSVC the stack traces read the PDB, which a release ships beside the executable.
		var files = [output + suffix => published];
		if (FileSystem.exists('$output.pdb'))
			files.set('$output.pdb', Path.withoutExtension(published) + ".pdb");
		for (from => to in files) {
			status = Sys.command("cmake", [
				'-DFROM=$from',
				'-DTO=$to',
				"-P",
				Path.join([home, "cmake", "haxeon-replace.cmake"])
			]);
			if (status != 0)
				return status;
		}
		File.saveContent(stamp + ".tmp", digest + "\n");
		FileSystem.rename(stamp + ".tmp", stamp);
		Sys.println('Published $published');
		return 0;
	}

	/** Whether the SDK's libraries are MSVC's (`lib/<target>` with the `msvc` ABI, as `build.Target` spells it). */
	static function msvcSdk(sdk:String):Bool {
		var libraries = Path.join([sdk, "lib"]);
		if (!FileSystem.exists(libraries))
			return false;
		for (target in FileSystem.readDirectory(libraries))
			if (StringTools.endsWith(target, "-msvc"))
				return true;
		return false;
	}

	static function collectSources(home:String, relative:String, into:Array<String>):Void {
		var entries = FileSystem.readDirectory(Path.join([home, relative]));
		for (entry in entries) {
			var child = relative + "/" + entry;
			if (FileSystem.isDirectory(Path.join([home, child])))
				collectSources(home, child, into);
			else if (StringTools.endsWith(entry, ".hx"))
				into.push(child);
		}
	}
}
