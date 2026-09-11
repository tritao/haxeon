package compiler.tools;

/** Parses and validates the stable command-line build interface. */
class CompilerArguments {
	public static function parse(arguments:Array<String>):CompilerRequest {
		var target = "hl", output = "out/main.hl", xmlOutput:Null<String> = null, irOutput:Null<String> = null, entry = "compiler.tools.HaxeonCompiler",
			dumpFunction = -1, importMemory = false, memoryBase = 0, memoryContract:Null<String> = null, exports:Array<String> = [], ffiHeader:Null<String> = null, ffiLibrary:Null<String> = null, ffiInterfaces:Array<String> = [], ffiProjections:Array<String> = [], roots:Array<String> = [],
			defines:Array<String> = [], paths:Array<String> = [];
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (StringTools.startsWith(argument, "--output="))
				output = value(argument, "--output=");
			else if (StringTools.startsWith(argument, "--target="))
				target = value(argument, "--target=");
			else if (StringTools.startsWith(argument, "--xml="))
				xmlOutput = value(argument, "--xml=");
			else if (argument == "--xml") {
				if (index >= arguments.length)
					throw 'Compiler option "--xml" requires a value';
				xmlOutput = arguments[index++];
				if (xmlOutput.length == 0)
					throw 'Compiler option "--xml" requires a value';
			} else if (StringTools.startsWith(argument, "--entry="))
				entry = value(argument, "--entry=");
			else if (StringTools.startsWith(argument, "--ir-output="))
				irOutput = value(argument, "--ir-output=");
			else if (StringTools.startsWith(argument, "--root="))
				roots.push(value(argument, "--root="));
			else if (StringTools.startsWith(argument, "--ffi-header="))
				ffiHeader = value(argument, "--ffi-header=");
			else if (StringTools.startsWith(argument, "--ffi-library="))
				ffiLibrary = value(argument, "--ffi-library=");
			else if (StringTools.startsWith(argument, "--ffi-interface="))
				ffiInterfaces.push(value(argument, "--ffi-interface="));
			else if (StringTools.startsWith(argument, "--ffi-projection="))
				ffiProjections.push(value(argument, "--ffi-projection="));
			else if (StringTools.startsWith(argument, "--define="))
				defines.push(parseDefine(value(argument, "--define=")));
			else if (StringTools.startsWith(argument, "--dump-function="))
				dumpFunction = parseIndex(value(argument, "--dump-function="));
			else if (argument == "--wasm-import-memory")
				importMemory = true;
			else if (StringTools.startsWith(argument, "--wasm-memory-base="))
				memoryBase = parseIndex(value(argument, "--wasm-memory-base="));
			else if (StringTools.startsWith(argument, "--wasm-memory-contract="))
				memoryContract = value(argument, "--wasm-memory-contract=");
			else if (StringTools.startsWith(argument, "--export="))
				exports.push(value(argument, "--export="));
			else if (StringTools.startsWith(argument, "--"))
				throw 'Unknown compiler option "$argument"';
			else
				paths.push(argument);
		}
		if ((ffiHeader == null) != (ffiLibrary == null))
			throw "--ffi-header and --ffi-library must be provided together";
		if (roots.length == 0)
			roots.push("src");
		if (paths.length == 0)
			throw "Haxeon compiler requires an explicit source manifest";
		if (target != "hl" && target != "wasm32" && target != "wasm64" && target != "wasmgc" && target != "wasm-gc")
			throw 'Unsupported compiler target "$target"';
		if ((importMemory || memoryBase != 0 || exports.length != 0) && target != "wasm32")
			throw "Wasm-specific options require --target=wasm32";
		if (memoryContract != null && target != "wasm32")
			throw "--wasm-memory-contract requires --target=wasm32";
		if (memoryContract != null && !importMemory)
			throw "--wasm-memory-contract requires --wasm-import-memory";
		if (memoryContract != null && memoryBase != 0)
			throw "--wasm-memory-contract and --wasm-memory-base are mutually exclusive";
		return {
			target: target,
			defines: defines,
			output: output,
			xmlOutput: xmlOutput,
			irOutput: irOutput,
			entry: entry,
			dumpFunction: dumpFunction,
			importMemory: importMemory,
			memoryBase: memoryBase,
			memoryContract: memoryContract,
			exports: exports,
			ffiHeader: ffiHeader,
			ffiLibrary: ffiLibrary,
			ffiInterfaces: ffiInterfaces,
			ffiProjections: ffiProjections,
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

	static function parseDefine(value:String):String {
		var separator = value.indexOf("=");
		var name = separator < 0 ? value : value.substr(0, separator);
		if (name.length == 0)
			throw 'Compiler option "--define=" requires a non-empty name';
		for (index in 0...name.length) {
			var code = name.charCodeAt(index);
			if (code == 32 || code == 9 || code == 10 || code == 13)
				throw 'Invalid conditional define name "$name"';
		}
		return value;
	}
}
