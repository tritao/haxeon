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
 * `haxeon dev aot [--toolchain=NAME]`: builds the CLI and the compiler ahead of time, one executable (`build.AotCompiler`),
 * from this checkout and publishes it beside the VM with its stamp, which is what a release ships for its platform. The checkout's compiler, built to
 * bytecode with the pinned Haxe, compiles `tools.CompilerExecutable` to C against the native build's hlc SDK, in release mode as
 * every tool artifact (`HaxeonBuild.TOOL_BUILD_MODE`), with the toolchain given or else the default of the SDK's target
 * (`compiler.backend.c.HlcBuild.toolchain`: `cc`, `clang-cl` on Windows with MSVC, MinGW's gcc with GNU's). The C sources and
 * objects stay in `out/aot`, so a rebuild after an edit compiles only the C files that changed.
 */
class AotBuild {
	public static function run(arguments:Array<String>, home:String):Int {
		var toolchain:Null<String> = null;
		for (argument in arguments)
			if (StringTools.startsWith(argument, "--toolchain="))
				toolchain = argument.substr("--toolchain=".length);
			else
				throw new InternalError('Usage: haxeon dev aot [--toolchain=NAME] (unexpected "$argument")');
		home = Path.normalize(home);
		var nativeStatus = build.HaxeonBuild.buildNative(new build.BuildEnvironment(home, Path.join([home, "out"])));
		if (nativeStatus != 0)
			return nativeStatus;
		var compiler = new ToolArtifacts(home).resolve({
			main: "compiler.tools.HaxeonCompiler",
			classPaths: [],
			defines: []
		}),
			sdk = Path.join([Path.directory(HashLinkPath.directory(home)), "hlc-sdk"]),
			directory = Path.join([home, "out", "aot"]),
			output = Path.join([directory, AotCompiler.NAME + (Sys.systemName() == "Windows" ? ".exe" : "")]),
			sourcesFile = Path.join([directory, "sources.txt"]),
			compilerSource = Path.join([home, "src"]);
		if (!FileSystem.exists(Path.join([sdk, "lib"])))
			throw new InternalError('No hlc SDK at $sdk: the native build makes it (target haxeon-hlc-sdk)');
		FileSystem.createDirectory(directory);
		var roots = ["src", "lib/haxeon-io", "stdlib"], sources = [];
		for (root in roots)
			collectSources(home, root, sources);
		sources.sort((left, right) -> left < right ? -1 : (left > right ? 1 : 0));
		File.saveContent(sourcesFile, sources.join("\n") + "\n");
		var digest = AotCompiler.sourcesDigest(home, compilerSource),
			arguments = [
				compiler,
				'--build-mode=${build.HaxeonBuild.TOOL_BUILD_MODE}',
				"--entry=tools.CompilerExecutable",
				'--sources-file=$sourcesFile',
				"--target=hlc",
				'--c-sdk=$sdk',
				'--output=$output'
			].concat([for (root in roots) '--root=$root']).concat(toolchain == null ? [] : ['--toolchain=$toolchain']);
		var status = ProcessRunner.run(HashLinkPath.executable(home), arguments, home,
			CompilerClient.runtimeLibraryEnvironment(home));
		if (status != 0)
			return status;
		// A source edited while it compiled would leave a stamp that the executable does not match.
		if (AotCompiler.sourcesDigest(home, compilerSource) != digest) {
			Sys.stderr().writeString("The compiler sources changed during the build; run it again\n");
			return 1;
		}
		// The stamp goes first and comes back last, so no moment pairs a new stamp with an old executable. A running worker keeps
		// the executable it started from: it is replaced by rename (cmake/haxeon-replace.cmake).
		var stamp = AotCompiler.stamp(home), published = AotCompiler.executable(home);
		if (FileSystem.exists(stamp))
			FileSystem.deleteFile(stamp);
		status = Sys.command("cmake", [
			'-DFROM=$output',
			'-DTO=$published',
			"-P",
			Path.join([home, "cmake", "haxeon-replace.cmake"])
		]);
		if (status != 0)
			return status;
		File.saveContent(stamp + ".tmp", digest + "\n");
		FileSystem.rename(stamp + ".tmp", stamp);
		Sys.println('Published $published');
		return 0;
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
