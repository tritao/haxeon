package build;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** Cross-platform entry point for Haxeon's build and bootstrap workflow. */
class HaxeonBuild {
	public static function main():Void {
		var arguments = Sys.args();
		var command = arguments.length == 0 ? "help" : arguments.shift();
		var status = switch command {
			case "native": native(arguments);
			case "bootstrap": bootstrap(false);
			case "bootstrap-self": bootstrap(true);
			case "test": test(arguments);
			case "doctor": doctor();
			case "help", "--help", "-h": usage();
			case _:
				Sys.stderr().writeString('Unknown command: $command\n');
				usage(2);
		};
		Sys.exit(status);
	}

	static function native(arguments:Array<String>):Int {
		var preset = arguments.length == 0 ? (Sys.systemName() == "Windows" ? "windows-msvc" : "release") : arguments[0];
		var configured = run("cmake", ["--preset", preset, "-S", root()]);
		return configured == 0 ? run("cmake", ["--build", "--preset", preset]) : configured;
	}

	static function bootstrap(selfOnly:Bool):Int {
		var nativeStatus = native([]);
		if (nativeStatus != 0)
			return nativeStatus;
		configureRuntimeLibraryPath();
		var outputDirectory = path("out", "bootstrap");
		if (!FileSystem.exists(outputDirectory))
			FileSystem.createDirectory(outputDirectory);
		var sources = sourceManifest();
		var checked = path("bootstrap", "compiler.hl");
		var self = path("out", "bootstrap", "compiler-self.hl");
		if (selfOnly) {
			var status = compileWith(checked, self, sources);
			if (status != 0)
				return status;
			if (!identical(checked, self) || !identical(checked + ".functions", self + ".functions")) {
				Sys.stderr().writeString("Self-hosted compiler output differs from the checked-in compiler\n");
				return 1;
			}
			Sys.println("PASS: checked-in compiler rebuilt itself identically");
			return 0;
		}

		var seed = path("out", "bootstrap", "compiler-seed.hl");
		var stageOne = path("out", "bootstrap", "compiler-stage-one.hl");
		var stageTwo = path("out", "bootstrap", "compiler-stage-two.hl");
		var stageThree = path("out", "bootstrap", "compiler-stage-three.hl");
		var status = run(haxe(), ["--cwd", root(), "-cp", "src", "--run", "compiler.tools.HaxeonCompiler"].concat(compilerArguments(seed, sources)));
		if (status != 0)
			return status;
		for (stage in [
			{compiler: seed, output: stageOne},
			{compiler: stageOne, output: stageTwo},
			{compiler: stageTwo, output: stageThree}
		]) {
			status = compileWith(stage.compiler, stage.output, sources);
			if (status != 0)
				return status;
		}
		if (!identical(stageTwo, stageThree) || !identical(stageTwo + ".functions", stageThree + ".functions")) {
			Sys.stderr().writeString("Bootstrap stages did not converge\n");
			return 1;
		}
		File.copy(stageThree, checked);
		File.copy(stageThree + ".functions", checked + ".functions");
		Sys.println("PASS: bootstrap stages converged on an identical self-hosted compiler");
		return 0;
	}

	static function test(arguments:Array<String>):Int {
		var jobs = arguments.length == 0 ? "4" : arguments[0];
		var nativeStatus = native([]);
		if (nativeStatus != 0)
			return nativeStatus;
		configureRuntimeLibraryPath();
		return run(haxe(), [
			"--cwd",
			root(),
			"-cp",
			"tests",
			"--run",
			"driver.TestDriver",
			"--root",
			root(),
			"--jobs",
			jobs
		]);
	}

	static function doctor():Int {
		var failed = false;
		for (tool in ["git", "cmake", "ninja"]) {
			var status = run(tool, ["--version"], false);
			Sys.println('${status == 0 ? "ok" : "missing"}: $tool');
			failed = failed || status != 0;
		}
		Sys.println('${FileSystem.exists(haxe()) ? "ok" : "missing"}: pinned Haxe');
		return failed || !FileSystem.exists(haxe()) ? 1 : 0;
	}

	static function compileWith(compiler:String, output:String, sources:Array<String>):Int {
		var status = run(hashlink(), [compiler].concat(compilerArguments(output, sources)));
		if (status != 0)
			Sys.stderr().writeString('HashLink compiler failed ($status): $compiler -> $output\n');
		return status;
	}

	static function compilerArguments(output:String, sources:Array<String>):Array<String>
		return [
			'--output=$output',
			"--entry=compiler.tools.HaxeonCompiler",
			"--root=src",
			"--root=stdlib"
		].concat(sources);

	static function sourceManifest():Array<String> {
		var result = [];
		for (directory in ["src", "stdlib"])
			collectSources(path(directory), result);
		result.sort(Reflect.compare);
		return result;
	}

	static function collectSources(directory:String, result:Array<String>):Void {
		var entries = FileSystem.readDirectory(directory);
		entries.sort(Reflect.compare);
		for (entry in entries) {
			var absolute = Path.join([directory, entry]);
			if (FileSystem.isDirectory(absolute))
				collectSources(absolute, result);
			else if (StringTools.endsWith(entry, ".hx"))
				result.push(Path.normalize(absolute).substr(Path.normalize(root()).length + 1));
		}
	}

	static function identical(left:String, right:String):Bool
		return FileSystem.exists(left) && FileSystem.exists(right) && File.getBytes(left).compare(File.getBytes(right)) == 0;

	static function configureRuntimeLibraryPath():Void {
		var directories = [path("out"), path(".tools", "hashlink")];
		var variable = Sys.systemName() == "Windows" ? "PATH" : (Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH");
		var existing = Sys.getEnv(variable);
		if (existing != null && existing != "")
			directories.push(existing);
		Sys.putEnv(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
	}

	static function haxe():String
		return path(".tools", "haxe", "haxe" + executableSuffix());

	static function hashlink():String
		return path(".tools", "hashlink", "hl" + executableSuffix());

	static function executableSuffix():String
		return Sys.systemName() == "Windows" ? ".exe" : "";

	static function path(...parts:String):String
		return Path.join([root()].concat(parts));

	static function run(command:String, arguments:Array<String>, inherit:Bool = true):Int {
		try {
			if (inherit)
				return Sys.command(command, arguments);
			var process = new Process(command, arguments);
			var status = process.exitCode();
			process.close();
			return status;
		} catch (_:Dynamic) {
			return 127;
		}
	}

	static function root():String
		return FileSystem.fullPath(Sys.getCwd());

	static function usage(status:Int = 0):Int {
		Sys.println("Usage: haxe -cp src --run build.HaxeonBuild <command>");
		Sys.println("  native [preset]  Configure and build HashLink and the runtime");
		Sys.println("  bootstrap        Rebuild the checked-in compiler through convergence");
		Sys.println("  bootstrap-self   Verify the checked-in compiler rebuilds identically");
		Sys.println("  test [jobs]      Run the cross-platform core test catalog");
		Sys.println("  doctor           Check required build tools");
		return status;
	}
}
