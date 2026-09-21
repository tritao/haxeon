package compiler.ffi;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

typedef ClangInvocationOptions = {
	final header:String;
	final target:String;
	final language:String;
	final standard:String;
	final includes:Array<String>;
	final defines:Array<String>;
	final clang:String;
	final compileCommands:Null<String>;
	final useHostTarget:Bool;
}

/** Builds the stable, diagnostic-friendly command line shared by C and C++. */
class ClangInvocation {
	final options:ClangInvocationOptions;

	static final hostTargets:Map<String, String> = [];

	/** Returns the target triple selected by the compiler executable itself. */
	public static function hostTarget(clang:String = "clang++"):String {
		var cached = hostTargets.get(clang);
		if (cached != null)
			return cached;
		var process = ProcessOutputCapture.capture(clang, ["-dumpmachine"], ProcessOutputCapture.defaultDiagnosticLimit),
			output = StringTools.trim(process.stdout);
		if (process.exitCode != 0 || output.length == 0)
			throw 'Clang "$clang" could not report its host target${output.length == 0 ? "" : ":\n$output"}';
		var target = StringTools.trim(output.split("\n")[0]);
		hostTargets.set(clang, target);
		return target;
	}

	public function new(options:ClangInvocationOptions) {
		if (options.language != "c" && options.language != "c++")
			throw 'Unsupported Clang language "${options.language}"';
		if (options.standard.length == 0)
			throw "Clang language standard cannot be empty";
		this.options = options;
	}

	public function arguments():Array<String> {
		var result = ["-x", options.language, '-std=${options.standard}'];
		if (!options.useHostTarget)
			result = result.concat(["-target", options.target]);
		result = result.concat(["-w", "-ferror-limit=1", "-fno-caret-diagnostics"]);
		// C++ headers commonly depend on the hosted standard library. Keeping
		// -ffreestanding for C preserves the existing C ABI import behavior, but
		// passing it to clang++ makes headers such as <vector> unusable.
		if (options.language == "c")
			result.insert(3, "-ffreestanding");
		var compileFlags = options.compileCommands == null ? [] : compileDatabaseFlags(options.compileCommands, options.header);
		for (flag in compileFlags)
			result.push(flag);
		for (include in options.includes)
			result.push('-I$include');
		for (define in options.defines)
			result.push('-D$define');
		return result;
	}

	function compileDatabaseFlags(path:String, header:String):Array<String> {
		if (!FileSystem.exists(path))
			throw 'Compilation database "$path" does not exist';
		var parsed:Dynamic;
		try {
			parsed = Json.parse(File.getContent(path));
		} catch (error:Dynamic)
			throw 'Could not parse compilation database "$path": $error';
		var entries:Array<Dynamic> = parsed;
		if (entries == null)
			throw 'Compilation database "$path" must contain an array';
		var headerPath = FileSystem.fullPath(header), selected:Dynamic = null;
		for (entry in entries) {
			var file:String = Reflect.field(entry, "file"),
				directory:String = Reflect.field(entry, "directory");
			if (file == null)
				continue;
			var candidate = isAbsolute(file) || directory == null ? file : Path.join([directory, file]),
				resolved = FileSystem.fullPath(candidate);
			if (resolved == headerPath) {
				selected = entry;
				break;
			}
			if (selected == null)
				selected = entry;
		}
		if (selected == null)
			throw 'Compilation database "$path" contains no commands';
		var directory:String = Reflect.field(selected, "directory"),
			arguments:Array<String> = Reflect.field(selected, "arguments");
		if (arguments == null) {
			var command:String = Reflect.field(selected, "command");
			if (command == null)
				throw 'Compilation database entry in "$path" has neither arguments nor command';
			arguments = splitCommand(command);
		}
		var result:Array<String> = [], index = 1;
		while (index < arguments.length) {
			var argument = arguments[index];
			if (argument == "-c" || argument == "-fsyntax-only") {
				index++;
				continue;
			}
			if (argument == "-o" || argument == "-MF" || argument == "-MT" || argument == "-MQ" || argument == "-include-pch") {
				index += 2;
				continue;
			}
			if (StringTools.startsWith(argument, "-std=")
				|| argument == "-std"
				|| StringTools.startsWith(argument, "-target=")
				|| argument == "-target"
				|| StringTools.startsWith(argument, "--target=")
				|| argument == "--target"
				|| argument == "-x"
				|| argument == "-Winvalid-pch") {
				index += argument == "-std" || argument == "-target" || argument == "--target" || argument == "-x" ? 2 : 1;
				continue;
			}
			if (!StringTools.startsWith(argument, "-") && isSourcePath(argument)) {
				index++;
				continue;
			}
			result.push(argument);
			index++;
		}
		if (directory != null)
			result = ["-working-directory", directory].concat(result);
		return result;
	}

	static function isSourcePath(path:String):Bool {
		var lower = path.toLowerCase();
		return StringTools.endsWith(lower, ".c") || StringTools.endsWith(lower, ".cc") || StringTools.endsWith(lower, ".cpp")
			|| StringTools.endsWith(lower, ".cxx") || StringTools.endsWith(lower, ".m") || StringTools.endsWith(lower, ".mm")
			|| StringTools.endsWith(lower, ".h") || StringTools.endsWith(lower, ".hh") || StringTools.endsWith(lower, ".hpp")
			|| StringTools.endsWith(lower, ".hxx");
	}

	static function isAbsolute(path:String):Bool
		return StringTools.startsWith(path, "/")
			|| (path.length > 2 && path.charAt(1) == ":" && (path.charAt(2) == "/" || path.charAt(2) == "\\"));

	static function splitCommand(command:String):Array<String> {
		var result:Array<String> = [], current = new StringBuf(), quote = "";
		for (index in 0...command.length) {
			var character = command.charAt(index);
			if (quote.length != 0) {
				if (character == quote)
					quote = "";
				else
					current.add(character);
			} else if (character == "'" || character == '"')
				quote = character;
			else if (character == " " || character == "\t" || character == "\r" || character == "\n") {
				if (current.length > 0) {
					result.push(current.toString());
					current = new StringBuf();
				}
			} else
				current.add(character);
		}
		if (current.length > 0)
			result.push(current.toString());
		return result;
	}
}
