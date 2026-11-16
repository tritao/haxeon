package tools.dev;

import build.HashLinkPath;
import sys.FileSystem;

/**
 * `haxeon dev test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]`: the test driver, with the options after the job count
 * passed to it (tests/driver/TestDriver.hx).
 *
 * The driver's first step is the native build, which publishes the VM by rename: this process and the driver keep running on
 * the file they started from. Program cases compile with the compiler prebuilt to HashLink (`HAXEON_MAIN_HL`), and both tools
 * come from the tool cache unless `HAXEON_BUILD_HL` or `HAXEON_MAIN_HL` pin a build. `HAXEON_TEST_INTERPRETED=1` compiles the
 * program cases with `haxe --run Main` instead, for debugging the compiler's sources under the Haxe interpreter.
 */
class TestDriverCommand {
	public static function run(arguments:Array<String>, home:String):Int {
		var jobs = "4", options = arguments;
		if (arguments.length > 0 && !StringTools.startsWith(arguments[0], "-")) {
			jobs = arguments[0];
			options = arguments.slice(1);
		}
		var vm = HashLinkPath.executable(home);
		if (!FileSystem.exists(vm)) {
			Sys.stderr().writeString('Missing $vm; build the native runtime first (scripts/build-native)\n');
			return 1;
		}
		var artifacts = new ToolArtifacts(home), buildTool = pinned("HAXEON_BUILD_HL");
		if (buildTool == null)
			buildTool = artifacts.resolve({main: "build.HaxeonBuild", classPaths: [], defines: []});
		if (Sys.getEnv("HAXEON_TEST_INTERPRETED") == "1")
			Sys.putEnv("HAXEON_MAIN_HL", "");
		else if (pinned("HAXEON_MAIN_HL") == null)
			Sys.putEnv("HAXEON_MAIN_HL", artifacts.resolve({main: "Main", classPaths: [], defines: []}));
		// The driver's progress as it happens, also into a pipe or a CI log (unless the caller chose).
		if (Sys.getEnv("HL_STDOUT_FLUSH") == null)
			Sys.putEnv("HL_STDOUT_FLUSH", "1");
		var previous = Sys.getCwd();
		Sys.setCwd(home);
		var status = Sys.command(vm, [buildTool, "test", jobs].concat(options));
		Sys.setCwd(previous);
		return status;
	}

	static function pinned(variable:String):Null<String> {
		var value = Sys.getEnv(variable);
		return value == null || value == "" ? null : value;
	}
}
