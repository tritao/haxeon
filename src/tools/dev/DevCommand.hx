package tools.dev;

import compiler.core.InternalError;
import haxe.io.Path;
import tools.dev.ToolArtifacts.ToolRequest;

/**
 * `haxeon dev`: commands for working on this checkout itself, not on a project.
 *
 *   haxeon dev tool-path [--cp DIR]... [--define NAME[=VALUE]]... MAIN
 *       Print the path of a HashLink build of the entry point MAIN, built with the pinned Haxe and cached by content (ToolArtifacts).
 *       Build diagnostics go to stderr; stdout is only the path.
 *
 *   haxeon dev hl-stat MODULE [--ops [N]] [--top N] [--dump NAME [--index I]] [--around OPCODE] [--sections]
 *       What a HashLink module is made of: part sizes, opcode counts, the largest functions, one function's instructions
 *       (HlStatCommand, reading with compiler.hl.HlModuleReader).
 *
 *   haxeon dev tool-build-mode
 *       Print the build mode tool artifacts are built in (build.HaxeonBuild.TOOL_BUILD_MODE), for scripts that build them.
 *
 *   haxeon dev run [--cp DIR]... [--define NAME[=VALUE]]... MAIN [arguments]
 *       Run that build of MAIN on this checkout's VM with the arguments and the caller's streams and directory.
 *
 *   haxeon dev format [--check] [--changed]
 *       Format the Haxe sources of the checkout, or check them (FormatCommand); the format-check suite and the pre-push hook run it.
 *
 *   haxeon dev test quick|wave|ci|full [--jobs N] [--gate] [--only NAME,...] [--list]
 *       Run a mode of tests/suites.txt (SuiteRunner), 16 jobs by default and 4 with --gate. scripts/test.sh runs it.
 *
 *   haxeon dev native [preset]
 *       Build the VM: HashLink with the Haxeon runtime compiled in (build.HaxeonBuild.buildNative).
 *
 *   haxeon dev test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]
 *       Run the test driver on private copies of the VM and runtime (TestDriverCommand). scripts/test-driver.sh runs it.
 *
 *   haxeon dev bootstrap [--self]
 *       Refresh the checked-in compiler, or check it against the sources (build.HaxeonBuild). scripts/bootstrap-compiler.sh runs it.
 *
 *   haxeon dev aot [--toolchain=NAME]
 *       Build the CLI and the compiler ahead of time to C, one executable, and publish it beside the VM, where the haxeon
 *       command and the CLI run it while it is current (build.AotCompiler, AotBuild): what a release ships prebuilt.
 *
 *   haxeon dev package [--output=DIR] [--version=VERSION] [--no-archive]
 *       Stage this checkout's release for this platform and archive it (ReleasePackage, docs/reference/RELEASES.md).
 *
 *   haxeon dev check-tests
 *       Fail on a test file under tests/ that no suite, test driver case or workflow runs (TestRegistration).
 */
class DevCommand {
	/** Runs the command in `arguments` on the checkout the SDK at `sdk` was built from: every command but hl-stat needs one. */
	public static function run(arguments:Array<String>, sdk:String):Int {
		var command = arguments.length == 0 ? "" : arguments.shift();
		if (command == "hl-stat")
			return HlStatCommand.run(arguments);
		var home = build.HaxeonSdk.source(sdk);
		if (home == null)
			throw new compiler.core
				.UsageError('haxeon dev is for working on Haxeon itself and runs only in a checkout of its sources '
				+ '(scripts/haxeon, or the checkout\'s out/sdk/bin/haxeon); this Haxeon ($sdk) is a release');
		return switch command {
			case "tool-path": toolPath(arguments, home);
			case "tool-build-mode":
				Sys.println(build.HaxeonBuild.TOOL_BUILD_MODE);
				0;
			case "run": runEntry(arguments, home);
			case "test": test(arguments, home);
			case "format": FormatCommand.run(arguments, home);
			case "check-tests": TestRegistration.run(arguments, home);
			case "test-driver": TestDriverCommand.run(arguments, home);
			case "native": native(arguments, home);
			case "bootstrap": bootstrap(arguments, home);
			case "aot": AotBuild.run(arguments, home);
			case "package": ReleasePackage.run(arguments, home);
			case "help", "--help", "-h", "": usage(command == "" ? 2 : 0);
			case _:
				Sys.stderr().writeString('Unknown dev command: $command\n');
				usage(2);
		};
	}

	static function toolPath(arguments:Array<String>, home:String):Int {
		var request = toolRequest(arguments, "tool-path");
		if (request == null)
			return usage(2);
		if (arguments.length != 0)
			throw new InternalError("tool-path takes one main class");
		Sys.println(new ToolArtifacts(home).resolve(request));
		return 0;
	}

	/** `haxeon dev run [--cp DIR]... [--define NAME[=VALUE]]... MAIN [arguments]`: run an entry point of this checkout. */
	static function runEntry(arguments:Array<String>, home:String):Int {
		var request = toolRequest(arguments, "run");
		return request == null ? usage(2) : new ToolArtifacts(home).run(request, arguments);
	}

	/** Reads the options and the main class from the front of `arguments`, leaving what follows the main class in it. */
	static function toolRequest(arguments:Array<String>, command:String):Null<ToolRequest> {
		var classPaths:Array<String> = [], defines:Array<String> = [];
		while (arguments.length > 0) {
			var argument = arguments.shift();
			switch argument {
				case "--cp" | "--define":
					if (arguments.length == 0)
						throw new InternalError('Option "$argument" takes a value');
					var value = arguments.shift();
					if (value == null)
						throw new InternalError('Option "$argument" takes a value');
					(argument == "--cp" ? classPaths : defines).push(value);
				case _ if (StringTools.startsWith(argument, "-")):
					throw new InternalError('Unknown $command option: $argument');
				case _:
					return {main: argument, classPaths: classPaths, defines: defines};
			}
		}
		return null;
	}

	static function test(arguments:Array<String>, home:String):Int {
		var mode:Null<String> = null,
			jobs = Std.parseInt(Sys.getEnv("TEST_JOBS") ?? ""),
			gate = false,
			list = false,
			only:Array<String> = [],
			index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			switch argument {
				case "--gate":
					gate = true;
				case "--list":
					list = true;
				case "--jobs" | "--only":
					if (index >= arguments.length)
						throw new InternalError('Option "$argument" takes a value');
					var value = arguments[index++];
					if (argument == "--jobs") {
						jobs = Std.parseInt(value);
						if (jobs == null || jobs < 1)
							throw new InternalError("--jobs takes a whole number of at least 1");
					} else
						only = only.concat(value.split(",").filter(name -> name != ""));
				case _ if (StringTools.startsWith(argument, "-")):
					throw new InternalError('Unknown test option: $argument');
				case _:
					if (mode != null)
						throw new InternalError("test takes one mode");
					mode = argument;
			}
		}
		if (mode == null || SuiteManifest.MODES.indexOf(mode) < 0)
			return usage(2);
		if (list)
			return SuiteRunner.list(home, mode);
		return SuiteRunner.run(home, {
			mode: mode,
			jobs: jobs == null || jobs < 1 ? (gate ? 4 : 16) : jobs,
			gate: gate,
			only: only
		});
	}

	/** The CMake build of the VM. It publishes the VM by rename, so the process running this command can rebuild it. */
	static function native(arguments:Array<String>, home:String):Int {
		if (arguments.length > 1)
			throw new InternalError("native takes at most a preset");
		var environment = new build.BuildEnvironment(home, Path.join([home, "out"]));
		return build.HaxeonBuild.buildNative(environment, arguments.length == 1 ? arguments[0] : null);
	}

	/** The bootstrap needs the pinned Haxe for its seed, so it runs under it: `build.HaxeonBuild bootstrap` or `bootstrap-self`. */
	static function bootstrap(arguments:Array<String>, home:String):Int {
		if (arguments.length > 1 || (arguments.length == 1 && arguments[0] != "--self"))
			throw new InternalError("bootstrap takes only --self");
		var pinnedHaxe = Path.join([home, ".tools", "haxe", Sys.systemName() == "Windows" ? "haxe.exe" : "haxe"]);
		return Sys.command(pinnedHaxe, [
			"--cwd",
			home,
			"common.hxml",
			"--run",
			"build.HaxeonBuild",
			arguments.length == 1 ? "bootstrap-self" : "bootstrap"
		]);
	}

	static function usage(status:Int):Int {
		var out = status == 0 ? Sys.stdout() : Sys.stderr();
		out.writeString("Usage: haxeon dev <command>   (commands for working on a Haxeon checkout)\n");
		out.writeString("  tool-path [--cp DIR]... [--define NAME[=VALUE]]... MAIN\n");
		out.writeString("      Print the path of a cached HashLink build of the entry point MAIN (built with the pinned Haxe)\n");
		out.writeString("  hl-stat MODULE [--ops [N]] [--top N] [--dump NAME [--index I]] [--around OPCODE] [--sections]\n");
		out.writeString("      What a HashLink module is made of: part sizes, opcodes, largest functions, one function's code\n");
		out.writeString("  tool-build-mode\n");
		out.writeString("      Print the build mode tool artifacts are built in (the checked-in bootstrap's)\n");
		out.writeString("  run [--cp DIR]... [--define NAME[=VALUE]]... MAIN [arguments]\n");
		out.writeString("      Run that build of MAIN with the arguments (the benchmarks: run --cp benchmarks BenchmarkMain)\n");
		out.writeString("  format [--check] [--changed]\n");
		out.writeString("      Format the checkout's Haxe sources, or check them; --changed: only files that differ from origin/main\n");
		out.writeString("  test quick|wave|ci|full [--jobs N] [--gate] [--only NAME,...] [--list]\n");
		out.writeString("      Run a mode of tests/suites.txt; --gate writes a report to out/gate (default jobs: TEST_JOBS, else 16)\n");
		out.writeString("  native [preset]\n");
		out.writeString("      Build the VM (HashLink with the Haxeon runtime compiled in); release, or windows-msvc on Windows\n");
		out.writeString("  test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]\n");
		out.writeString("      Run the test driver, or the cases selected (suites: compiler, programs, runtime, tooling; default jobs: 4)\n");
		out.writeString("  bootstrap [--self]\n");
		out.writeString("      Refresh bootstrap/compiler.hl from the sources; --self: check that it rebuilds itself identically\n");
		out.writeString("  aot [--toolchain=NAME]\n");
		out.writeString("      Build the CLI and the compiler to C (default toolchain: the hlc SDK's target's) and publish them beside the VM\n");
		out.writeString("  package [--output=DIR] [--version=VERSION] [--no-archive]\n");
		out.writeString("      Stage this platform's release in DIR (default out/release) and archive it\n");
		out.writeString("  check-tests\n");
		out.writeString("      Fail on a test file under tests/ that no suite, test driver case or workflow runs\n");
		return status;
	}
}
