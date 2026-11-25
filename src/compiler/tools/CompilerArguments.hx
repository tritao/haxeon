package compiler.tools;

import compiler.backend.Backend.BackendTarget;
import compiler.backend.BackendTargets;
import compiler.core.UsageError;
import compiler.tools.CompilerRequest.CompileSessionMode;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import compiler.tools.DiagnosticPrinter.DiagnosticFormat;
import sys.io.File;

/** Parses and validates the stable command-line build interface. */
class CompilerArguments {
	/** The options that take a value, as `--name=value` or `--name value`. */
	static final VALUED = [
		"--output", "--api-json", "--target", "--build-mode", "--entry", "--ir-output", "--inputs-output", "--baseline",
		"--baseline-output",
		"--entry-id-output", "--root", "--sources-file", "--package-root", "--ffi-header", "--ffi-library",
		"--ffi-interface",
		"--ffi-projection", "--define", "--dump-function", "--session", "--verbosity", "--diagnostic-format", "--color",
		"--diagnostic-directory", "--stdlib", "--wasm-memory-base", "--wasm-memory-contract", "--export",
		"--null-safety"
	];

	public static function parse(arguments:Array<String>):CompilerRequest {
		arguments = joinValues(arguments);
		var target = "hl",
			buildMode = "development",
			output = "out/main.hl",
			apiJsonOutput:Null<String> = null,
			irOutput:Null<String> = null,
			inputsOutput:Null<String> = null,
			baseline:Null<String> = null,
			baselineOutput:Null<String> = null,
			entryIdOutput:Null<String> = null,
			entry = "compiler.tools.HaxeonCompiler",
			dumpFunction = -1,
			live = false,
			noOutput = false,
			buildModeExplicit = false,
			importMemory = false,
			sharedMemory = false,
			memoryBase = 0,
			memoryContract:Null<String> = null,
			wasmMemoryStats = false,
			wasmGcAllocationCount = false,
			wasmGcStress = false,
			wasmRuntimeNeutral = false,
			exports:Array<String> = [],
			ffiHeader:Null<String> = null,
			ffiLibrary:Null<String> = null,
			ffiInterfaces:Array<String> = [],
			ffiProjections:Array<String> = [],
			roots:Array<String> = [],
			stdlib = "stdlib",
			defines:Array<String> = [],
			paths:Array<String> = [],
			optionFlags:Array<String> = [],
			session = CompileSessionMode.Reuse,
			verbosity = Verbosity.Normal,
			diagnosticFormat = DiagnosticFormat.Short,
			color = false,
			diagnosticDirectory:Null<String> = null;
		var packageRoots:Array<PackageSourceRoot> = [];
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (StringTools.startsWith(argument, "--output="))
				output = value(argument, "--output=");
			else if (StringTools.startsWith(argument, "--target="))
				target = value(argument, "--target=");
			else if (StringTools.startsWith(argument, "--build-mode=")) {
				buildMode = value(argument, "--build-mode=");
				buildModeExplicit = true;
			}
				else if (StringTools.startsWith(argument, "--api-json="))
				apiJsonOutput = value(argument, "--api-json=");
			else if (StringTools.startsWith(argument, "--entry="))
				entry = value(argument, "--entry=");
			else if (StringTools.startsWith(argument, "--ir-output="))
				irOutput = value(argument, "--ir-output=");
			else if (StringTools.startsWith(argument, "--inputs-output="))
				inputsOutput = value(argument, "--inputs-output=");
			else if (StringTools.startsWith(argument, "--baseline="))
				baseline = value(argument, "--baseline=");
			else if (StringTools.startsWith(argument, "--baseline-output="))
				baselineOutput = value(argument, "--baseline-output=");
			else if (StringTools.startsWith(argument, "--entry-id-output="))
				entryIdOutput = value(argument, "--entry-id-output=");
			else if (StringTools.startsWith(argument, "--root="))
				roots.push(value(argument, "--root="));
			else if (StringTools.startsWith(argument, "--stdlib="))
				stdlib = value(argument, "--stdlib=");
			else if (StringTools.startsWith(argument, "--sources-file=")) {
				var manifest = File.getContent(value(argument, "--sources-file="));
				for (path in manifest.split("\n")) {
					if (StringTools.endsWith(path, "\r"))
						path = path.substr(0, path.length - 1);
					if (path.length > 0)
						paths.push(path);
				}
			} else if (StringTools.startsWith(argument, "--package-root="))
				packageRoots.push(packageRoot(value(argument, "--package-root=")));
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
			else if (compiler.CompileOptions.isFlag(argument))
				optionFlags.push(argument);
			else if (StringTools.startsWith(argument, "--session="))
				session = switch value(argument, "--session=") {
					case "reuse": CompileSessionMode.Reuse;
					case "fresh": CompileSessionMode.Fresh;
					case other: throw new UsageError('Compiler option "--session=" takes reuse or fresh, not "$other"');
				};
			else if (StringTools.startsWith(argument, "--verbosity=")) {
				var level = Verbosity.parse(value(argument, "--verbosity="));
				if (level == null)
					throw new UsageError('Compiler option "--verbosity=" takes ${Verbosity.NAMES.join(", ")}, not "${value(argument, "--verbosity=")}"');
				verbosity = level;
			} else if (StringTools.startsWith(argument, "--diagnostic-format=")) {
				var format = DiagnosticFormat.parse(value(argument, "--diagnostic-format="));
				if (format == null)
					throw new UsageError('Compiler option "--diagnostic-format=" takes ${DiagnosticFormat.NAMES.join(", ")}, not "${value(argument, "--diagnostic-format=")}"');
				diagnosticFormat = format;
			} else if (StringTools.startsWith(argument, "--color="))
				color = switch value(argument, "--color=") {
					case "always": true;
					case "never": false;
					case other: throw new UsageError('Compiler option "--color=" takes always, never, not "$other"');
				};
			else if (StringTools.startsWith(argument, "--diagnostic-directory="))
				diagnosticDirectory = value(argument, "--diagnostic-directory=");
			else if (argument == "--live")
				live = true;
			else if (argument == "--no-output")
				noOutput = true;
			else if (argument == "--wasm-shared-memory")
				sharedMemory = true;
			else if (argument == "--wasm-import-memory")
				importMemory = true;
			else if (StringTools.startsWith(argument, "--wasm-memory-base="))
				memoryBase = parseIndex(value(argument, "--wasm-memory-base="));
			else if (StringTools.startsWith(argument, "--wasm-memory-contract="))
				memoryContract = value(argument, "--wasm-memory-contract=");
			else if (argument == "--wasm-memory-stats")
				wasmMemoryStats = true;
			else if (argument == "--wasm-gc-allocation-count")
				wasmGcAllocationCount = true;
			else if (argument == "--wasm-gc-stress")
				wasmGcStress = true;
			else if (argument == "--wasm-runtime-neutral")
				wasmRuntimeNeutral = true;
			else if (StringTools.startsWith(argument, "--export="))
				exports.push(value(argument, "--export="));
			else if (StringTools.startsWith(argument, "--"))
				throw new UsageError('Unknown compiler option "$argument"');
			else
				paths.push(argument);
		}
		if ((ffiHeader == null) != (ffiLibrary == null))
			throw new UsageError("--ffi-header and --ffi-library must be provided together");
		if (roots.length == 0)
			roots.push("src");
		if (paths.length == 0)
			throw new UsageError("Haxeon compiler requires an explicit source manifest");
		var backend = BackendTargets.parse(target);
		if (backend == Wasm64)
			throw new UsageError('Compiler target "wasm64" is not implemented yet; use --target=wasm32 or --target=wasm-gc');
		if (backend == null)
			throw new UsageError('Unknown compiler target "$target". Valid: ${BackendTargets.names().join(", ")}');
		var wasm = BackendTargets.isWasm(backend);
		if ((importMemory || memoryBase != 0) && !wasm)
			throw new UsageError("Wasm memory options require --target=wasm32 or --target=wasm-gc");
		if (live && backend != HashLink)
			throw new UsageError("--live requires --target=hl");
		if (noOutput
			&& (live || baselineOutput != null || entryIdOutput != null || apiJsonOutput != null
			|| irOutput != null
			|| inputsOutput != null || ffiHeader != null))
			throw new UsageError("--no-output writes nothing, so it takes no option that writes a file or a live publication");
		if (baseline != null && !live)
			throw new UsageError("--baseline requires --live");
		if ((baselineOutput != null || entryIdOutput != null) && backend != HashLink)
			throw new UsageError("--baseline-output and --entry-id-output require --target=hl");
		if (buildMode != "release" && buildMode != "development")
			throw new UsageError('Unknown compiler build mode "$buildMode". Valid: development, release');
		if (live && buildModeExplicit && buildMode != "development")
			throw new UsageError("--live requires development build mode");
		if (live) buildMode = "development";
		if (buildMode == "release" && optionFlags.indexOf(compiler.CompileOptions.VERIFY_IR) < 0)
			optionFlags.push(compiler.CompileOptions.NO_VERIFY_IR);
		if ((wasmMemoryStats || wasmGcStress) && backend != Wasm32)
			throw new UsageError("Wasm allocator options require --target=wasm32");
		if (wasmGcAllocationCount && backend != WasmGc)
			throw new UsageError("--wasm-gc-allocation-count requires --target=wasm-gc");
		if (wasmRuntimeNeutral && backend != Wasm32)
			throw new UsageError("--wasm-runtime-neutral requires --target=wasm32");
		if (exports.length != 0 && !wasm)
			throw new UsageError("Function exports require a Wasm32 or Wasm GC target");
		if (memoryContract != null && !wasm)
			throw new UsageError("--wasm-memory-contract requires --target=wasm32 or --target=wasm-gc");
		if (sharedMemory && (!importMemory || memoryContract == null))
			throw new UsageError("--wasm-shared-memory requires imported memory and a bounded memory contract");
		if (memoryContract != null && !importMemory)
			throw new UsageError("--wasm-memory-contract requires --wasm-import-memory");
		if (memoryContract != null && memoryBase != 0)
			throw new UsageError("--wasm-memory-contract and --wasm-memory-base are mutually exclusive");
		var options = compiler.CompileOptions.fromArguments(optionFlags);
		return {
			target: target,
			buildMode: buildMode,
			defines: defines,
			output: output,
			apiJsonOutput: apiJsonOutput,
			irOutput: irOutput,
			inputsOutput: inputsOutput,
			baseline: baseline,
			baselineOutput: baselineOutput,
			entryIdOutput: entryIdOutput,
			entry: entry,
			dumpFunction: dumpFunction,
			importMemory: importMemory,
			sharedMemory: sharedMemory,
			memoryBase: memoryBase,
			memoryContract: memoryContract,
			wasmMemoryStats: wasmMemoryStats,
			wasmGcAllocationCount: wasmGcAllocationCount,
			wasmGcStress: wasmGcStress,
			wasmRuntimeNeutral: wasmRuntimeNeutral,
			options: options,
			session: session,
			verbosity: verbosity,
			diagnosticFormat: diagnosticFormat,
			color: color,
			diagnosticDirectory: diagnosticDirectory,
			live: live,
			noOutput: noOutput,
			exports: exports,
			ffiHeader: ffiHeader,
			ffiLibrary: ffiLibrary,
			ffiInterfaces: ffiInterfaces,
			ffiProjections: ffiProjections,
			roots: roots,
			stdlib: stdlib,
			packageRoots: packageRoots,
			paths: paths
		};
	}

	/** `--name value` as `--name=value`, for the options in VALUED: the compiler takes either, as the project CLI does. */
	static function joinValues(arguments:Array<String>):Array<String> {
		var result = [], index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (VALUED.indexOf(argument) >= 0) {
				if (index >= arguments.length)
					throw new UsageError('Compiler option "$argument" requires a value');
				argument += "=" + arguments[index++];
			}
			result.push(argument);
		}
		return result;
	}

	static function value(argument:String, prefix:String):String {
		var result = argument.substring(prefix.length, argument.length);
		if (result.length == 0)
			throw new UsageError('Compiler option "$prefix" requires a value');
		return result;
	}

	static function packageRoot(value:String):PackageSourceRoot {
		var separator = value.indexOf("=");
		if (separator <= 0 || separator == value.length - 1)
			throw new UsageError('Invalid package source root "$value"; expected NAME=PATH');
		return {packageName: value.substr(0, separator), path: value.substr(separator + 1)};
	}

	static function parseIndex(value:String):Int {
		var result = 0;
		for (index in 0...value.length) {
			var digit = value.charCodeAt(index) - 48;
			if (digit < 0 || digit > 9)
				throw new UsageError('Invalid function index "$value"');
			result = result * 10 + digit;
		}
		return result;
	}

	static function parseDefine(value:String):String {
		var separator = value.indexOf("=");
		var name = separator < 0 ? value : value.substr(0, separator);
		if (name.length == 0)
			throw new UsageError('Compiler option "--define=" requires a non-empty name');
		for (index in 0...name.length) {
			var code = name.charCodeAt(index);
			if (code == 32 || code == 9 || code == 10 || code == 13)
				throw new UsageError('Invalid conditional define name "$name"');
		}
		return value;
	}
}
