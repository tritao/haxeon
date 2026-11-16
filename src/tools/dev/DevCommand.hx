package tools.dev;

import haxe.io.Path;

/**
 * `haxeon dev`: commands for working on this checkout itself, not on a project.
 *
 *   haxeon dev tool-path [--cp DIR]... [--define NAME[=VALUE]]... MAIN
 *       Print the path of a HashLink build of the entry point MAIN, built with the pinned Haxe and cached by content (ToolArtifacts).
 *       Build diagnostics go to stderr; stdout is only the path.
 *
 *   haxeon dev format [--check] [--changed]
 *       Format the Haxe sources of the checkout, or check them (FormatCommand). scripts/format.sh runs it.
 *
 *   haxeon dev test quick|wave|ci|full [--jobs N] [--gate] [--only NAME,...] [--list]
 *       Run a mode of tests/suites.txt (SuiteRunner). scripts/test.sh runs `ci`; scripts/gate.sh runs the others with --gate.
 *
 *   haxeon dev test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]
 *       Run the test driver on private copies of the VM and runtime (TestDriverCommand). scripts/test-driver.sh runs it.
 *
 *   haxeon dev bootstrap [--self]
 *       Refresh the checked-in compiler, or check it against the sources (build.HaxeonBuild). scripts/bootstrap-compiler.sh runs it.
 *
 *   haxeon dev check-tests
 *       Fail on a test file under tests/ that no suite, test driver case or workflow runs (TestRegistration).
 */
class DevCommand {
	public static function run(arguments:Array<String>, home:String):Int {
		var command = arguments.length == 0 ? "" : arguments.shift();
		return switch command {
			case "tool-path": toolPath(arguments, home);
			case "test": test(arguments, home);
			case "format": FormatCommand.run(arguments, home);
			case "check-tests": TestRegistration.run(arguments, home);
			case "test-driver": TestDriverCommand.run(arguments, home);
			case "bootstrap": bootstrap(arguments, home);
			case "help", "--help", "-h", "": usage(command == "" ? 2 : 0);
			case _:
				Sys.stderr().writeString('Unknown dev command: $command\n');
				usage(2);
		};
	}

	static function toolPath(arguments:Array<String>, home:String):Int {
		var main:Null<String> = null, classPaths = [], defines = [], index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			switch argument {
				case "--cp" | "--define":
					if (index >= arguments.length)
						throw 'Option "$argument" takes a value';
					(argument == "--cp" ? classPaths : defines).push(arguments[index++]);
				case _ if (StringTools.startsWith(argument, "-")):
					throw 'Unknown tool-path option: $argument';
				case _:
					if (main != null)
						throw "tool-path takes one main class";
					main = argument;
			}
		}
		if (main == null)
			return usage(2);
		Sys.println(new ToolArtifacts(home).resolve({main: main, classPaths: classPaths, defines: defines}));
		return 0;
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
						throw 'Option "$argument" takes a value';
					var value = arguments[index++];
					if (argument == "--jobs") {
						jobs = Std.parseInt(value);
						if (jobs == null || jobs < 1)
							throw "--jobs takes a whole number of at least 1";
					} else
						only = only.concat(value.split(",").filter(name -> name != ""));
				case _ if (StringTools.startsWith(argument, "-")):
					throw 'Unknown test option: $argument';
				case _:
					if (mode != null)
						throw "test takes one mode";
					mode = argument;
			}
		}
		if (mode == null || SuiteManifest.MODES.indexOf(mode) < 0)
			return usage(2);
		if (list)
			return SuiteRunner.list(home, mode);
		return SuiteRunner.run(home, {
			mode: mode,
			jobs: jobs == null || jobs < 1 ? 16 : jobs,
			gate: gate,
			only: only
		});
	}

	/** The bootstrap needs the pinned Haxe for its seed, so it runs under it: `build.HaxeonBuild bootstrap` or `bootstrap-self`. */
	static function bootstrap(arguments:Array<String>, home:String):Int {
		if (arguments.length > 1 || (arguments.length == 1 && arguments[0] != "--self"))
			throw "bootstrap takes only --self";
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
		out.writeString("  format [--check] [--changed]\n");
		out.writeString("      Format the checkout's Haxe sources, or check them; --changed: only files that differ from origin/main\n");
		out.writeString("  test quick|wave|ci|full [--jobs N] [--gate] [--only NAME,...] [--list]\n");
		out.writeString("      Run a mode of tests/suites.txt; --gate writes a report to out/gate (default jobs: TEST_JOBS, else 16)\n");
		out.writeString("  test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]\n");
		out.writeString("      Run the test driver, or the cases selected (suites: compiler, programs, runtime, tooling; default jobs: 4)\n");
		out.writeString("  bootstrap [--self]\n");
		out.writeString("      Refresh bootstrap/compiler.hl from the sources; --self: check that it rebuilds itself identically\n");
		out.writeString("  check-tests\n");
		out.writeString("      Fail on a test file under tests/ that no suite, test driver case or workflow runs\n");
		return status;
	}
}
