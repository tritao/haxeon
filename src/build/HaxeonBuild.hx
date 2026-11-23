package build;

import compiler.core.InternalError;
import haxe.io.Path;
import build.BuildEnvironment;
import build.BuildPlanner;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ExecutionPlan;
import build.execution.Executor;
import build.execution.ProcessRunner;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import sys.FileSystem;
import sys.io.File;

/** Cross-platform entry point for Haxeon's build and bootstrap workflow. */
class HaxeonBuild {
	static var environment:BuildEnvironment;
	static var processActionNumber = 0;

	public static function main():Void {
		environment = BuildEnvironment.fromCurrentDirectory("out");
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

	static function native(arguments:Array<String>):Int
		return buildNative(environment, arguments.length == 0 ? null : arguments[0]);

	/**
	 * The CMake build of the VM, `preset` or the host's default. The VM is published by rename, never written in place,
	 * so a process running it, this one included, can rebuild it.
	 */
	public static function buildNative(environment:BuildEnvironment, ?preset:String):Int {
		if (preset == null)
			preset = Sys.systemName() == "Windows" ? "windows-msvc" : "release";
		var plan = BuildPlanner.nativeRuntime(environment, preset),
			execution = PlanLowerer.lower(plan, new LoweringContext(environment, preset)),
			result = new Executor(environment, 1).execute(execution);
		return result.exitCode;
	}

	static function bootstrap(selfOnly:Bool):Int {
		var nativeStatus = native([]);
		if (nativeStatus != 0)
			return nativeStatus;
		configureRuntimeLibraryPath();
		var outputDirectory = path(["out", "bootstrap"]);
		if (!FileSystem.exists(outputDirectory))
			FileSystem.createDirectory(outputDirectory);
		var sources = sourceManifest();
		var sourcesFile = path(["out", "bootstrap", "compiler-sources.txt"]);
		File.saveContent(sourcesFile, sources.join("\n") + "\n");
		var checked = path(["bootstrap", "compiler.hl"]);
		var self = path(["out", "bootstrap", "compiler-self.hl"]);
		if (selfOnly) {
			var status = compileWith(checked, self, sourcesFile);
			if (status != 0)
				return status;
			if (!identical(checked, self) || !identical(checked + ".functions", self + ".functions")) {
				Sys.stderr().writeString("Self-hosted compiler output differs from the checked-in compiler\n");
				return 1;
			}
			Sys.println("PASS: checked-in compiler rebuilt itself identically");
			return 0;
		}

		var seed = path(["out", "bootstrap", "compiler-seed.hl"]);
		var status = run(haxe(), ["--cwd", root(), "common.hxml", "--run",
			"compiler.tools.HaxeonCompiler"].concat(compilerArguments(seed, sourcesFile)));
		if (status != 0)
			return status;
		var compiler = seed;
		for (stage in 1...9) {
			var output = path(["out", "bootstrap", 'compiler-stage-$stage.hl']);
			status = compileWith(compiler, output, sourcesFile);
			if (status != 0)
				return status;
			if (identical(compiler, output) && identical(compiler + ".functions", output + ".functions")) {
				File.copy(output, checked);
				File.copy(output + ".functions", checked + ".functions");
				Sys.println('PASS: bootstrap stages converged after $stage self-host stages');
				return 0;
			}
			compiler = output;
		}
		Sys.stderr().writeString("Bootstrap stages did not converge within the stage limit\n");
		return 1;
	}

	static function test(arguments:Array<String>):Int {
		var jobs = arguments.length == 0 ? "4" : arguments[0];
		var nativeStatus = native([]);
		if (nativeStatus != 0)
			return nativeStatus;
		configureRuntimeLibraryPath();
		// Program cases compile with the compiler prebuilt to bytecode, as scripts/test-driver.sh gives them: interpreting the
		// whole compiler with `haxe --run` for every one of them did not finish within the Windows job's hour.
		var prebuilt = Sys.getEnv("HAXEON_COMPILER_SERVER_HL");
		if (prebuilt == null || prebuilt == "")
			Sys.putEnv("HAXEON_COMPILER_SERVER_HL", new tools.dev.ToolArtifacts(root()).resolve({
				main: "compiler.tools.CompilerServer",
				classPaths: [],
				defines: []
			}));
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null || temp == "")
			temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (temp == null || temp == "")
			throw new InternalError("No system temporary directory for the test driver");
		var work:String;
		do {
			work = Path.join([temp, 'haxeon-test-driver-${Std.random(0x3fffffff)}-${Std.random(0x3fffffff)}']);
		} while (FileSystem.exists(work));
		FileSystem.createDirectory(work);
		var driver = Path.join([work, "test-driver.hl"]), status:Int;
		try {
			// `src` for the compile server's wire format (compiler.tools.CompilerServerProtocol), which the driver speaks.
			status = run(haxe(), [
				"--cwd", root(), "-cp", "tests", "-cp", "src", "-hl", driver, "-main", "driver.TestDriver"
			]);
			if (status == 0)
				status = run(hashlink(), [driver, "--root", root(), "--jobs", jobs].concat(arguments.slice(1)));
		} catch (error:haxe.Exception) {
			if (FileSystem.exists(driver)) FileSystem.deleteFile(driver);
			FileSystem.deleteDirectory(work);
			throw error;
		}
		if (FileSystem.exists(driver)) FileSystem.deleteFile(driver);
		FileSystem.deleteDirectory(work);
		return status;
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

	static function compileWith(compiler:String, output:String, sourcesFile:String):Int {
		var status = run(hashlink(), [compiler].concat(compilerArguments(output, sourcesFile)));
		if (status != 0)
			Sys.stderr().writeString('HashLink compiler failed ($status): $compiler -> $output\n');
		return status;
	}

	/**
	 * The build mode of a tool artifact: the checked-in bootstrap compiler now, and the compile server, CLI and language server
	 * when Haxeon builds them. Tools are release builds (ADR 0003 section 12): smaller and quicker to load, with the function
	 * identities and line table kept inline so their crash traces still name functions and lines; nothing reads development
	 * metadata (source snapshots, opcode spans, live patch metadata) from a tool's own bytecode. scripts/check-self-hosting.hx
	 * reaches its fixed point in the same mode, so what the bootstrap is built with is what the compiler compiling itself tests.
	 */
	public static inline final TOOL_BUILD_MODE = "release";

	static function compilerArguments(output:String, sourcesFile:String):Array<String>
		return [
			'--output=$output',
			'--build-mode=$TOOL_BUILD_MODE',
			"--entry=compiler.tools.HaxeonCompiler",
			"--root=src",
			"--root=stdlib",
			'--sources-file=$sourcesFile'
		];

	static function sourceManifest():Array<String> {
		var result = [];
		for (directory in ["src", "lib", "stdlib"])
			collectSources(path([directory]), result);
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
		return FileSystem.exists(left) && FileSystem.exists(right)
			&& File.getBytes(left).compare(File.getBytes(right)) == 0;

	/** The test libraries the driver's programs load into the VM by name are in out/. */
	static function configureRuntimeLibraryPath():Void {
		var directories = [path(["out"])];
		Sys.putEnv("HAXEON_SDK", HaxeonSdk.root(root()));
		var variable = Sys.systemName() == "Windows"
			? "PATH" : (Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH");
		var existing = Sys.getEnv(variable);
		if (existing != null && existing != "")
			directories.push(existing);
		Sys.putEnv(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
	}

	static function haxe():String
		return path([".tools", "haxe", "haxe" + executableSuffix()]);

	static function hashlink():String
		return HashLinkPath.executable(root());

	static function executableSuffix():String
		return Sys.systemName() == "Windows" ? ".exe" : "";

	/** `parts` joined below the repository root. */
	static function path(parts:Array<String>):String
		return Path.join([root()].concat(parts));

	static function run(command:String, arguments:Array<String>, inherit:Bool = true):Int {
		if (!inherit)
			try {
				return ProcessRunner.run(command, arguments, root(), new Map(), false);
			} catch (_:Dynamic) {
				return 127;
			}
		try {
			processActionNumber++;
			var action = new ExecutionAction(new ActionId('build-command-$processActionNumber'), [], [], [],
				'$command ${arguments.join(" ")}',
				Process(command, arguments, root(), new Map())),
				result = new Executor(environment, 1).execute(new ExecutionPlan([action]));
			return result.exitCode;
		} catch (_:Dynamic) {
			return 127;
		}
	}

	static function root():String
		return environment.projectRoot;

	static function usage(status:Int = 0):Int {
		Sys.println("Usage: haxe common.hxml --run build.HaxeonBuild <command>");
		Sys.println("  native [preset]  Configure and build HashLink and the runtime");
		Sys.println("  bootstrap        Rebuild the checked-in compiler through convergence");
		Sys.println("  bootstrap-self   Verify the checked-in compiler rebuilds identically");
		Sys.println("  test [jobs] [--suite NAMES] [--test REGEX] [--list]  Run the test driver, or the cases selected");
		Sys.println("  doctor           Check required build tools");
		return status;
	}
}
