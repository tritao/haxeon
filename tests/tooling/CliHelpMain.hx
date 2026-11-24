import haxe.io.Path;
import sys.io.Process;

class CliHelpMain {
	static function main():Void {
		var launcher = Path.join([
			Sys.getEnv("HAXEON_SDK"),
			"bin",
			Sys.systemName() == "Windows" ? "haxeon.exe" : "haxeon"
		]);
		function help(words:Array<String>):String {
			var process = new Process(launcher, words.concat(["--help"]));
			var output = process.stdout.readAll().toString();
			var errors = process.stderr.readAll().toString();
			var status = process.exitCode();
			process.close();
			if (status != 0 || output.indexOf("Usage:") < 0 || errors != "")
				throw 'haxeon ${words.join(" ")} --help exited $status:\n$output$errors';
			return output;
		}
		var listed = ~/^  ([a-z][a-z-]+) +\S/;
		var usage = ~/^ *(?:Usage: +)?haxeon ([a-z][a-z-]+) ([a-z][a-z-]*(?:\|[a-z][a-z-]*)*)(?: +|$)/;
		var dev = ~/^  ([a-z][a-z-]+)( |$)/;
		for (line in help([]).split("\n")) {
			if (!listed.match(line))
				continue;
			var command = listed.matched(1);
			for (detail in help([command]).split("\n")) {
				if (command == "dev") {
					if (dev.match(detail))
						help([command, dev.matched(1)]);
				} else if (usage.match(detail) && usage.matched(1) == command) {
					for (subcommand in usage.matched(2).split("|"))
						help([command, subcommand]);
				}
			}
		}
		help(["dev", "help"]);
	}
}
