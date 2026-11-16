package tools.dev;

import build.HashLinkPath;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon dev test-driver [jobs] [--suite NAMES] [--test REGEX] [--list]`: the test driver, with the options after the job count
 * passed to it (tests/driver/TestDriver.hx).
 *
 * The driver's first step is the native build, which must not replace a library the process running it has loaded. So the
 * build tool runs on copies of the VM, `libhl` and the runtime in a directory of its own, with the directories the build
 * writes to taken off its library search path. Program cases compile with the compiler prebuilt to HashLink (`HAXEON_MAIN_HL`),
 * and both tools come from the tool cache unless `HAXEON_BUILD_HL` or `HAXEON_MAIN_HL` pin a build. `HAXEON_TEST_INTERPRETED=1`
 * compiles the program cases with `haxe --run Main` instead, for debugging the compiler's sources under the Haxe interpreter.
 *
 * This process still has the checkout's libraries loaded, so build the native runtime before starting it (scripts/test-driver.sh
 * does): the driver's own native build then has nothing to replace.
 */
class TestDriverCommand {
	public static function run(arguments:Array<String>, home:String):Int {
		var jobs = "4", options = arguments;
		if (arguments.length > 0 && !StringTools.startsWith(arguments[0], "-")) {
			jobs = arguments[0];
			options = arguments.slice(1);
		}
		var windows = Sys.systemName() == "Windows",
			hashlink = HashLinkPath.directory(home),
			vm = HashLinkPath.executable(home),
			runtime = Path.join([home, "out", "haxeon_runtime.hdll"]);
		for (required in [vm, runtime])
			if (!FileSystem.exists(required)) {
				Sys.stderr().writeString('Missing $required; build the native runtime first (scripts/build-native)\n');
				return 1;
			}
		var artifacts = new ToolArtifacts(home), buildTool = pinned("HAXEON_BUILD_HL");
		if (buildTool == null)
			buildTool = artifacts.resolve({main: "build.HaxeonBuild", classPaths: [], defines: []});
		if (Sys.getEnv("HAXEON_TEST_INTERPRETED") == "1")
			Sys.putEnv("HAXEON_MAIN_HL", "");
		else if (pinned("HAXEON_MAIN_HL") == null)
			Sys.putEnv("HAXEON_MAIN_HL", artifacts.resolve({main: "Main", classPaths: [], defines: []}));

		var work = Path.join([
			temporaryRoot(),
			'haxeon-test-driver-${Std.int(Sys.time() * 1000)}-${Std.random(1000000)}'
		]);
		FileSystem.createDirectory(work);
		try {
			var privateVm = Path.join([work, Path.withoutDirectory(vm)]);
			File.copy(vm, privateVm);
			if (!windows)
				Sys.command("chmod", ["+x", privateVm]);
			File.copy(runtime, Path.join([work, "haxeon_runtime.hdll"]));
			for (name in FileSystem.readDirectory(hashlink))
				if (isVmLibrary(name, windows))
					File.copy(Path.join([hashlink, name]), Path.join([work, name]));
			var separator = windows ? ";" : ":",
				built = [Path.join([home, "out"]), hashlink],
				variables = windows ? ["PATH"] : ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"];
			for (variable in variables) {
				var kept = [work];
				for (entry in (Sys.getEnv(variable) ?? "").split(separator))
					if (entry != "" && !isOneOf(entry, built))
						kept.push(entry);
				Sys.putEnv(variable, kept.join(separator));
			}
			var previous = Sys.getCwd();
			Sys.setCwd(home);
			var status = Sys.command(privateVm, [buildTool, "test", jobs].concat(options));
			Sys.setCwd(previous);
			removeTree(work);
			return status;
		} catch (error:Dynamic) {
			removeTree(work);
			throw error;
		}
	}

	static function pinned(variable:String):Null<String> {
		var value = Sys.getEnv(variable);
		return value == null || value == "" ? null : value;
	}

	/** `libhl` under its platform's names; on Windows also the DLLs HashLink is built with, which sit beside `hl.exe`. */
	static function isVmLibrary(name:String, windows:Bool):Bool
		return windows
			? StringTools.endsWith(name.toLowerCase(), ".dll")
			: StringTools.startsWith(name, "libhl")
			&& (name.indexOf(".so") >= 0 || StringTools.endsWith(name, ".dylib"));

	static function isOneOf(entry:String, directories:Array<String>):Bool {
		var normalized = Path.removeTrailingSlashes(Path.normalize(entry));
		for (directory in directories)
			if (normalized == Path.removeTrailingSlashes(Path.normalize(directory)))
				return true;
		return false;
	}

	static function temporaryRoot():String {
		for (variable in ["TMPDIR", "TEMP", "TMP"]) {
			var value = Sys.getEnv(variable);
			if (value != null && value != "" && FileSystem.exists(value))
				return value;
		}
		return "/tmp";
	}

	static function removeTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path))
				removeTree(Path.join([path, name]));
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}
}
