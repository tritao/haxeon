package build;

import sys.FileSystem;
import sys.io.Process;

/** Cross-platform entry point for Haxeon's build and bootstrap workflow. */
class HaxeonBuild {
	public static function main():Void {
		var arguments = Sys.args();
		var command = arguments.length == 0 ? "help" : arguments.shift();
		var status = switch command {
			case "native": native(arguments);
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

	static function doctor():Int {
		var failed = false;
		for (tool in ["git", "cmake", "ninja"]) {
			var status = run(tool, ["--version"], false);
			Sys.println('${status == 0 ? "ok" : "missing"}: $tool');
			failed = failed || status != 0;
		}
		var haxe = root() + "/.tools/haxe/haxe" + (Sys.systemName() == "Windows" ? ".exe" : "");
		Sys.println('${FileSystem.exists(haxe) ? "ok" : "missing"}: pinned Haxe');
		return failed || !FileSystem.exists(haxe) ? 1 : 0;
	}

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
		Sys.println("  doctor           Check required build tools");
		return status;
	}
}
