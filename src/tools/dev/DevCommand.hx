package tools.dev;

/**
 * `haxeon dev`: commands for working on this checkout itself, not on a project.
 *
 *   haxeon dev tool-path [--cp DIR]... [--define NAME[=VALUE]]... MAIN
 *       Print the path of a HashLink build of the entry point MAIN, built with the pinned Haxe and cached by content (ToolArtifacts).
 *       Build diagnostics go to stderr; stdout is only the path.
 */
class DevCommand {
	public static function run(arguments:Array<String>, home:String):Int {
		var command = arguments.length == 0 ? "" : arguments.shift();
		return switch command {
			case "tool-path": toolPath(arguments, home);
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

	static function usage(status:Int):Int {
		var out = status == 0 ? Sys.stdout() : Sys.stderr();
		out.writeString("Usage: haxeon dev <command>   (commands for working on a Haxeon checkout)\n");
		out.writeString("  tool-path [--cp DIR]... [--define NAME[=VALUE]]... MAIN\n");
		out.writeString("      Print the path of a cached HashLink build of the entry point MAIN (built with the pinned Haxe)\n");
		return status;
	}
}
