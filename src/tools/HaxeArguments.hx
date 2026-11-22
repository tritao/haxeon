package tools;

import compiler.core.InternalError;
import compiler.core.UsageError;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** A Haxe library a compilation uses (`-lib NAME:VERSION`), resolved through the Haxelib adapter. */
typedef HaxeLibrary = {
	final name:String;
	final version:String;
}

/** One compilation of a Haxe command line, in the terms a Haxeon build takes (`HaxeonCli.haxeCommandLine`). */
typedef HaxeCompilation = {
	/** The directory its paths are relative to: where the command ran, or the last `--cwd` before the compilation ended. */
	final directory:String;

	/** `-cp`, absolute, the one Haxe looks in first (the last given) first, and then `directory`, as Haxe's are. */
	final classPaths:Array<String>;

	/** `-main`, or null. */
	final main:Null<String>;

	/** The dot paths given besides `-main`: modules Haxe compiles even if nothing imports them. */
	final modules:Array<String>;

	/** `-D NAME[=VALUE]`, and `debug` for `--debug`, as Haxe defines it. */
	final defines:Array<String>;

	final libraries:Array<HaxeLibrary>;

	/** `--hl FILE`, absolute; null when the compilation names no target, which Haxe then only types. */
	final hl:Null<String>;

	/** `--no-output`: type the program without writing it. */
	final noOutput:Bool;

	/** `--debug`: a development build, with the metadata debuggers read. */
	final debug:Bool;

	final noInline:Bool;
	final verbose:Bool;
	final times:Bool;

	/** `--cmd`, run by the shell in `directory` after the compilation succeeds, in order. */
	final commands:Array<String>;
}

/** An argument with the directory it is relative to. */
private typedef Located = {
	final value:String;
	final directory:String;
}

/**
 * A Haxe command line (`haxeon -cp src -main Main --hl out.hl`, `haxeon build.hxml`) read the way Haxe reads it, as the builds
 * it asks for.
 *
 * An `.hxml` file holds one argument per line, its first word and the rest of the line when the line starts with `-`
 * (`-D name=a b` is `-D` and `name=a b`), with surrounding quotes removed; a line starting with `#` is a comment, and a `#`
 * later in a line is part of it, as in Haxe. An argument ending in `.hxml` is replaced by the file's arguments. Paths, the
 * `.hxml` files' included, are relative to the working directory (which `--cwd` changes), not to the file that names them. `--next` separates
 * compilations and `--each` gives the arguments before it to every one. Everything Haxeon does not build (another target,
 * macros, `--interp`, ...) is one usage error that lists each.
 */
class HaxeArguments {
	/** Haxe's flags that take a value, by their long name: an unsupported one is skipped with its value. */
	static final VALUED = [
		"--class-path", "--main", "--define", "--library", "--hl", "--dce", "--cmd", "--cwd", "--js", "--lua", "--swf",
		"--neko", "--php", "--cpp", "--cppia", "--cs", "--java", "--jvm", "--python", "-x", "--connect", "--remap",
		"--macro", "--resource", "--display", "--xml", "--json", "--swf-version", "--swf-header", "--swf-lib",
		"--swf-lib-extern", "--java-lib", "--java-lib-extern", "--net-lib", "--net-std", "--c-arg", "--server-listen",
		"--server-connect", "--wait"
	];

	/** The other targets, which Haxeon does not generate. */
	static final TARGETS = [
		"--js", "--lua", "--swf", "--neko", "--php", "--cpp", "--cppia", "--cs", "--java", "--jvm", "--python"
	];

	/** Whether `argument` is how a Haxe command line starts: an .hxml file or one of Haxe's own flags. */
	public static function isHaxeArgument(argument:String):Bool {
		if (StringTools.endsWith(argument, ".hxml"))
			return true;
		var flag = longName(argument);
		return flag != argument || VALUED.indexOf(flag) >= 0
			|| ["--debug", "--interp", "--run", "--no-output", "--no-inline", "--each", "--next"].indexOf(flag) >= 0;
	}

	/** The arguments of an `.hxml` file's text, as Haxe reads them. */
	public static function hxmlArguments(text:String):Array<String> {
		var result = [];
		for (rawLine in ~/[\r\n]+/g.split(text)) {
			var line = unquote(StringTools.trim(rawLine));
			if (line == "" || StringTools.startsWith(line, "#"))
				continue;
			var space = line.indexOf(" ");
			if (StringTools.startsWith(line, "-") && space > 0) {
				result.push(unquote(line.substr(0, space)));
				result.push(unquote(StringTools.trim(line.substr(space + 1))));
			} else
				result.push(line);
		}
		return result;
	}

	/** The compilations `arguments` ask for, run from `directory`. Throws one UsageError naming everything Haxeon does not support. */
	public static function parse(arguments:Array<String>, directory:String):Array<HaxeCompilation> {
		var unsupported:Array<String> = [];
		var compilations = [
			for (segment in segments(arguments, directory, unsupported))
				compilation(segment, directory, unsupported)
		];
		if (unsupported.length > 0) {
			var unique = [];
			for (item in unsupported)
				if (unique.indexOf(item) < 0)
					unique.push(item);
			throw new UsageError("this Haxe command line uses what Haxeon does not support:\n  " + unique.join("\n  ")
				+ "\nSee 'Haxe command lines' in docs/reference/CLI.md.");
		}
		return compilations;
	}

	/** The flag's long name: Haxe's short and single-dash forms (`-cp`, `-p`, `-main`, `-lib`, `-hl`, ...) as `--class-path` and so on. */
	static function longName(argument:String):String
		return switch argument {
			case "-cp", "-p": "--class-path";
			case "-m", "-main": "--main";
			case "-D": "--define";
			case "-L", "-lib": "--library";
			case "-C": "--cwd";
			case "-v": "--verbose";
			case "-r", "-resource": "--resource";
			case "-x": "-x";
			case _ if (StringTools.startsWith(argument, "-") && !StringTools.startsWith(argument, "--")
				&& argument.length > 2): "-" + argument;
			case _: argument;
		};

	/**
	 * The arguments of each compilation, with `.hxml` files read in place and `--each` given to every compilation, as Haxe's own
	 * loop does. `--cwd` changes the working directory for the rest of the run, as Haxe's does for its process: an .hxml file
	 * named after it is read from there, and a compilation's paths are relative to the directory it is in when the compilation
	 * ends (at its `--next`, or the end), whichever argument named them. An empty compilation between two `--next` is skipped.
	 */
	static function segments(arguments:Array<String>, directory:String,
			unsupported:Array<String>):Array<Array<Located>> {
		var pending:Array<Located> = [for (argument in arguments) {
			value:argument, directory:directory
		}],
			current = directory,
			each:Array<Located> = [],
			accumulated:Array<Located> = [],
			result:Array<Array<Located>> = [],
			files = 0;
		while (pending.length > 0) {
			var argument:Located = pending.shift(), flag = longName(argument.value);
			if (flag == "--next") {
				if (accumulated.length > 0)
					result.push(located(each.concat(accumulated), current));
				accumulated = [];
			} else if (flag == "--each") {
				each = accumulated;
				accumulated = [];
			} else if (flag == "--cwd") {
				if (pending.length == 0)
					throw new UsageError('Haxe option "${argument.value}" requires a directory');
				var directoryArgument:Located = pending.shift(), target = resolve(current, directoryArgument.value);
				if (!FileSystem.exists(target) || !FileSystem.isDirectory(target))
					throw new UsageError('Invalid directory: $target');
				current = target;
			} else if (flag == "--run") {
				unsupported.push("--run " + [for (rest in pending) rest.value].join(" ")
					+ ": Haxeon has no interpreter; build with --hl FILE and run it with hl, or use 'haxeon run'");
				pending = [];
			} else if (StringTools.endsWith(argument.value, ".hxml") && !isCommandValue(accumulated)) {
				var path = resolve(current, argument.value);
				if (!FileSystem.exists(path) || FileSystem.isDirectory(path))
					throw new InternalError('File not found: ${argument.value}');
				if (++files > 256)
					throw new UsageError('.hxml files include each other in a cycle (at ${argument.value})');
				var included:Array<Located> = [for (value in hxmlArguments(File.getContent(path))) {
					value:value, directory:current
				}];
				pending = included.concat(pending);
			} else
				accumulated.push({value: argument.value, directory: current});
		}
		if (accumulated.length > 0 || result.length == 0)
			result.push(located(each.concat(accumulated), current));
		return result;
	}

	/** `arguments`, each relative to `directory`. */
	static function located(arguments:Array<Located>, directory:String):Array<Located>
		return [for (argument in arguments) {
			value:argument.value, directory:directory
		}];

	static function isCommandValue(accumulated:Array<Located>):Bool
		return accumulated.length > 0 && longName(accumulated[accumulated.length - 1].value) == "--cmd";

	static function compilation(arguments:Array<Located>, directory:String, unsupported:Array<String>):HaxeCompilation {
		var classPaths:Array<String> = [],
			main:Null<String> = null,
			modules:Array<String> = [],
			defines:Array<String> = [],
			libraries:Array<HaxeLibrary> = [],
			hl:Null<String> = null,
			noOutput = false,
			debug = false,
			noInline = false,
			verbose = false,
			times = false,
			commands:Array<String> = [],
			index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++], flag = longName(argument.value);
			var value:Null<String> = null;
			if (VALUED.indexOf(flag) >= 0) {
				if (index >= arguments.length)
					throw new UsageError('Haxe option "${argument.value}" requires a value');
				value = arguments[index++].value;
			}
			switch flag {
				case "--class-path":
					classPaths.push(resolve(argument.directory, value));
				case "--main":
					main = value;
				case "--define":
					defines.push(value);
				case "--library":
					var library:String = value, colon = library.indexOf(":");
					if (colon > 0 && colon < library.length - 1)
						libraries.push({name: value.substr(0, colon), version: value.substr(colon + 1)});
					else
						unsupported.push('${argument.value} $value: give the version (-lib $value:VERSION), or declare the dependency in haxeon.json; Haxeon does not read haxelib\'s global repository');
				case "--hl":
					if (Path.extension(value) == "c")
						unsupported.push('${argument.value} $value: HashLink/C output is not supported yet; write a .hl file');
					else
						hl = resolve(argument.directory, value);
				case "--dce":
					switch value {
						case "std", "full":
						// Haxeon always removes what the entry cannot reach.
						case "no":
							unsupported.push('${argument.value} no: Haxeon always removes code the entry cannot reach');
						case _:
							throw new UsageError('Invalid DCE mode "$value". Valid: std, full, no');
					}
				case "--cmd":
					commands.push(value);
				case "--debug":
					debug = true;
				case "--no-output":
					noOutput = true;
				case "--no-inline":
					noInline = true;
				case "--verbose":
					verbose = true;
				case "--times":
					times = true;
				case "--interp", "-x":
					unsupported.push(argument.value + (value == null ? "" : " " + value)
						+ ": Haxeon has no interpreter; build with --hl FILE and run it with hl, or use 'haxeon run'");
				case "--macro":
					unsupported.push('${argument.value} $value: macros are not supported');
				case _ if (TARGETS.indexOf(flag) >= 0):
					unsupported.push('${argument.value} $value: Haxeon generates HashLink (--hl FILE) only');
				case _ if (StringTools.startsWith(flag, "-")):
					unsupported.push(argument.value + (value == null ? "" : " " + value));
				case _ if (~/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.match(argument.value)):
					modules.push(argument.value);
				case _:
					unsupported.push('${argument.value}: not a Haxe option, a dot path or an .hxml file');
			}
		}
		if (debug)
			defines.push("debug");
		// Haxe looks in the last class path given first, and in the working directory, always a class path, last.
		var workingDirectory = Path.normalize(arguments.length == 0 ? directory : arguments[0].directory);
		classPaths.reverse();
		if (classPaths.indexOf(workingDirectory) < 0)
			classPaths.push(workingDirectory);
		return {
			directory: workingDirectory,
			classPaths: classPaths,
			main: main,
			modules: modules,
			defines: defines,
			libraries: libraries,
			hl: hl,
			noOutput: noOutput,
			debug: debug,
			noInline: noInline,
			verbose: verbose,
			times: times,
			commands: commands
		};
	}

	/** The file of module `dotPath` in the first class path that has it, or null. */
	public static function moduleFile(compilation:HaxeCompilation, dotPath:String):Null<String> {
		var relative = dotPath.split(".").join("/") + ".hx";
		for (root in compilation.classPaths) {
			var path = Path.join([root, relative]);
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
				return path;
		}
		return null;
	}

	static function resolve(directory:String, path:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([directory, path]));

	/** A value without the quotes around it, as Haxe reads an .hxml line. */
	static function unquote(value:String):String {
		if (value.length >= 2) {
			var first = value.charAt(0), last = value.charAt(value.length - 1);
			if ((first == '"' && last == '"') || (first == "'" && last == "'"))
				return value.substr(1, value.length - 2);
		}
		return value;
	}
}
