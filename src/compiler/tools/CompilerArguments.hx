package compiler.tools;

/** Parses and validates the stable command-line build interface. */
class CompilerArguments {
	public static function parse(arguments:Array<String>):CompilerRequest {
		var target = "hl", output = "out/main.hl", entry = "compiler.tools.HaxeonCompiler", dumpFunction = -1, ffiHeader:Null<String> = null,
			ffiLibrary:Null<String> = null, roots:Array<String> = [], paths:Array<String> = [];
		for (argument in arguments)
			if (StringTools.startsWith(argument, "--output="))
				output = value(argument, "--output=");
			else if (StringTools.startsWith(argument, "--target="))
				target = value(argument, "--target=");
			else if (StringTools.startsWith(argument, "--entry="))
				entry = value(argument, "--entry=");
			else if (StringTools.startsWith(argument, "--root="))
				roots.push(value(argument, "--root="));
			else if (StringTools.startsWith(argument, "--ffi-header="))
				ffiHeader = value(argument, "--ffi-header=");
			else if (StringTools.startsWith(argument, "--ffi-library="))
				ffiLibrary = value(argument, "--ffi-library=");
			else if (StringTools.startsWith(argument, "--dump-function="))
				dumpFunction = parseIndex(value(argument, "--dump-function="));
			else if (StringTools.startsWith(argument, "--"))
				throw 'Unknown compiler option "$argument"';
			else
				paths.push(argument);
		if ((ffiHeader == null) != (ffiLibrary == null))
			throw "--ffi-header and --ffi-library must be provided together";
		if (roots.length == 0)
			roots.push("src");
		if (paths.length == 0)
			throw "Haxeon compiler requires an explicit source manifest";
		if (target != "hl" && target != "wasm32")
			throw 'Unsupported compiler target "$target"';
		return {
			target: target,
			output: output,
			entry: entry,
			dumpFunction: dumpFunction,
			ffiHeader: ffiHeader,
			ffiLibrary: ffiLibrary,
			roots: roots,
			paths: paths
		};
	}

	static function value(argument:String, prefix:String):String {
		var result = argument.substring(prefix.length, argument.length);
		if (result.length == 0)
			throw 'Compiler option "$prefix" requires a value';
		return result;
	}

	static function parseIndex(value:String):Int {
		var result = 0;
		for (index in 0...value.length) {
			var digit = value.charCodeAt(index) - 48;
			if (digit < 0 || digit > 9)
				throw 'Invalid function index "$value"';
			result = result * 10 + digit;
		}
		return result;
	}
}
