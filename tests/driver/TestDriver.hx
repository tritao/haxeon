package driver;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef DriverOptions = {
	var root:String;
	var suites:Array<String>;
	var filter:Null<EReg>;
	var listOnly:Bool;
}

private typedef ProgramCase = {
	var name:String;
	var expectedExit:Int;
}

private enum CompileStep {
	HaxeMain(main:String, arguments:Array<String>);
	Hxml(path:String);
}

private typedef ExecutableCase = {
	var suite:String;
	var name:String;
	var compile:CompileStep;
	var output:String;
	var runtimeArguments:Array<String>;
	var expectedExit:Null<Int>;
	var message:String;
}

class TestDriver {
	static final compilerMains = [
		"TestMain",
		"ExternMain",
		"CaptureAnalysisMain",
		"ModuleCanonicalizerMain",
		"SemanticDependencyCollectorMain",
		"ResolvedSemanticDependencyMain",
		"InvalidationMain",
		"IrProgramAssemblerMain",
		"ModuleChangeAnalyzerMain",
		"SemanticModelMain",
		"SemanticWorkspaceMain",
		"SemanticProgramMain",
		"AbiMatrixMain",
		"ParserRecoveryMain",
		"ParserRecoveryFuzzMain",
		"ConditionalCompilationMain",
		"FunctionTypeSyntaxMain",
	];

	static final toolingMains = ["LanguageServiceMain", "ProtocolMain", "LspProtocolMain", "UtestDiscoveryMain"];
	static final runtimeMains = ["RuntimeDomainMain"];

	static function main():Void {
		var options = parseOptions(Sys.args());
		configureRuntimeLibraryPath(options.root);
		var failures = 0;
		var selected = 0;

		for (entry in namedCases()) {
			if (!matches(options, entry.suite, entry.name))
				continue;
			selected++;
			if (options.listOnly) {
				Sys.println('${entry.suite}\t${entry.name}');
				continue;
			}
			if (!runHaxeMain(options.root, entry.name))
				failures++;
		}

		for (test in executableCases()) {
			if (!matches(options, test.suite, test.name))
				continue;
			selected++;
			if (options.listOnly) {
				Sys.println('${test.suite}\t${test.name}');
				continue;
			}
			if (!runExecutable(options.root, test))
				failures++;
		}

		var programs = loadPrograms(options.root);
		validateProgramManifest(options.root, programs);
		for (program in programs) {
			if (!matches(options, "programs", program.name))
				continue;
			selected++;
			if (options.listOnly) {
				Sys.println('programs\t${program.name}');
				continue;
			}
			if (!runProgram(options.root, program))
				failures++;
		}

		if (selected == 0)
			throw "No tests matched the requested suite and filter";
		if (options.listOnly)
			return;
		Sys.println('Test driver: ${selected - failures} passed, $failures failed, $selected total');
		if (failures != 0)
			Sys.exit(1);
	}

	static function configureRuntimeLibraryPath(root:String):Void {
		var paths = [Path.join([root, "out"]), Path.join([root, "vendor", "hashlink"])];
		var existing = Sys.getEnv("LD_LIBRARY_PATH");
		if (existing != null && existing != "")
			paths.push(existing);
		Sys.putEnv("LD_LIBRARY_PATH", paths.join(":"));
	}

	static function namedCases():Array<{suite:String, name:String}> {
		var result = [];
		for (name in compilerMains)
			result.push({suite: "compiler", name: name});
		for (name in toolingMains)
			result.push({suite: "tooling", name: name});
		for (name in runtimeMains)
			result.push({suite: "runtime", name: name});
		return result;
	}

	static function runHaxeMain(root:String, name:String):Bool {
		var haxe = Path.join([root, ".tools", "haxe", "haxe"]);
		var args = [
			"--cwd",
			root,
			"-cp",
			"src",
			"-cp",
			"tests",
			"-cp",
			"tests/compiler",
			"-cp",
			"tests/runtime",
			"-cp",
			"tests/tooling",
			"--run",
			name
		];
		var status = Sys.command(haxe, args);
		if (status == 0)
			return true;
		Sys.stderr().writeString('FAIL: $name exited with $status\n');
		return false;
	}

	static function executableCases():Array<ExecutableCase> {
		return [
			mainCase("runtime", "exceptions", "ExceptionMain", "exception.hl", 42, "exceptions can be chained, thrown, caught, and inspected"),
			mainCase("runtime", "ereg", "ERegMain", "ereg.hl", 42, "regex literals and EReg operations executed"),
			mainCase("runtime", "list", "ListMain", "list.hl", 42, "Array-backed List insertion and iteration executed"),
			mainCase("runtime", "array-splice", "ArraySpliceMain", "array-splice.hl", 42, "Array.splice mutation and removed values executed"),
			mainCase("runtime", "reflect-methods", "ReflectMethodsMain", "reflect-methods.hl", 42,
				"Reflect.compareMethods preserves static and bound method identity"),
			mainCase("runtime", "null-reference", "NullReferenceMain", "null-reference.hl", 42,
				"null coerces to reference-like types while primitives remain strict"),
			mainCase("runtime", "stdlib", "StdlibMain", "stdlib.hl", 42, "vendored stdlib compiled and executed"),
			mainCase("tooling", "utest-basic", "UtestMain", "utest-basic.hl", 0, "utest-compatible assertions and runner executed"),
			mainCase("tooling", "utest-failure", "UtestMain", "utest-failure.hl", 5, "utest-compatible runner reports assertion failures",
				["{output}", "tests/programs/utest-failure.hx"]),
			mainCase("tooling", "utest-hook-failure", "UtestMain", "utest-hook-failure.hl", 2, "utest-compatible lifecycle hook failures are isolated",
				["{output}", "tests/programs/utest-hook-failure.hx"]),
			hxmlCase("tooling", "repl", "tests/hxml/repl-test.hxml", "repl-test.hl", 0, "compiler-backed integer REPL expression executed"),
			hxmlCase("tooling", "plugin", "tests/hxml/plugin-test.hxml", "plugin-test.hl", 0, "stateful plugin workload executed",
				["{root}/out/plugin-runtime.hl"]),
			hxmlCase("runtime", "static-init-order", "tests/hxml/static-init-order-test.hxml", "static-init-order-test.hl", 0,
				"static initializers respect dependency order"),
			hxmlCase("runtime", "instance-initializer", "tests/hxml/instance-initializer-test.hxml", "instance-initializer-test.hl", 0,
				"instance initializer constructor invalidation"),
			mainCase("runtime", "object", "ObjectMain", "object.hl", 42, "object allocation and field access executed"),
			mainCase("runtime", "closure", "ClosureMain", "closure.hl", 42, "static closure allocation and invocation executed"),
			mainCase("runtime", "instance-closure", "InstanceClosureMain", "instance-closure.hl", 42, "instance closure capture ABI executed"),
			mainCase("runtime", "collection", "CollectionMain", "collection.hl", 42, "native-backed collection object executed"),
			mainCase("runtime", "array", "ArrayMain", "array.hl", 42, "first-class Array<Int> indexing executed"),
			mainCase("runtime", "array-allocation", "ArrayAllocMain", "compiler-array.hl", 47,
				"compiler-owned Int/Float/Bool/String array allocation executed"),
			mainCase("runtime", "value-struct", "ValueStructMain", "value-struct.hl", 42, "HSTRUCT value and HPACKED embedded field executed"),
			mainCase("runtime", "string", "StringMain", "string.hl", 42, "compiler-owned string concatenation executed"),
			mainCase("runtime", "import", "ImportMain", "import.hl", 42, "package-qualified import executed"),
			mainCase("runtime", "import-class", "ImportClassMain", "import-class.hl", 42, "imported nominal class executed"),
			mainCase("runtime", "namespace", "NamespaceMain", "namespace.hl", 42, "qualified nominal namespaces executed"),
			mainCase("runtime", "instance-module", "InstanceModuleMain", "instance-module.hl", 42, "incremental instance class executed"),
			hxmlCase("runtime", "static-field", "tests/hxml/static-field-test.hxml", "static-field-test.hl", 0, "static fields lower to persistent globals"),
			mainCase("compiler", "modules", "ModuleMain", "modules.hl", 42, "incrementally rebuilt multi-module program executed"),
			mainCase("runtime", "array-bounds", "ArrayBoundsMain", "array-bounds.hl", null, "HashLink array bounds check rejected invalid index"),
		];
	}

	static function mainCase(suite:String, name:String, main:String, output:String, expectedExit:Null<Int>, message:String,
			?arguments:Array<String>):ExecutableCase {
		return {
			suite: suite,
			name: name,
			compile: HaxeMain(main, arguments == null ? ["{output}"] : arguments),
			output: output,
			runtimeArguments: [],
			expectedExit: expectedExit,
			message: message
		};
	}

	static function hxmlCase(suite:String, name:String, hxml:String, output:String, expectedExit:Int, message:String,
			?runtimeArguments:Array<String>):ExecutableCase {
		return {
			suite: suite,
			name: name,
			compile: Hxml(hxml),
			output: output,
			runtimeArguments: runtimeArguments == null ? [] : runtimeArguments,
			expectedExit: expectedExit,
			message: message
		};
	}

	static function runExecutable(root:String, test:ExecutableCase):Bool {
		var haxe = Path.join([root, ".tools", "haxe", "haxe"]);
		var output = Path.join([root, "out", test.output]);
		var compileStatus = switch test.compile {
			case HaxeMain(main, arguments):
				var args = haxeMainArguments(root, main);
				args = args.concat(resolveArguments(root, output, arguments));
				Sys.command(haxe, args);
			case Hxml(path):
				Sys.command(haxe, ["--cwd", root, Path.join([root, path])]);
		};
		if (compileStatus != 0) {
			Sys.stderr().writeString('FAIL: ${test.name} setup failed\n');
			return false;
		}
		var arguments = [output].concat(resolveArguments(root, output, test.runtimeArguments));
		var status = Sys.command(Path.join([root, "vendor", "hashlink", "hl"]), arguments);
		var passed = test.expectedExit == null ? status != 0 : status == test.expectedExit;
		if (!passed) {
			var expected = test.expectedExit == null ? "a non-zero exit" : 'exit ${test.expectedExit}';
			Sys.stderr().writeString('FAIL: ${test.name} expected $expected, got $status\n');
			return false;
		}
		var exitDescription = test.expectedExit == null ? 'non-zero exit $status' : 'exit ${test.expectedExit}';
		Sys.println('PASS: ${test.message} ($exitDescription)');
		return true;
	}

	static function haxeMainArguments(root:String, main:String):Array<String> {
		return [
			"--cwd",
			root,
			"-cp",
			"src",
			"-cp",
			"tests",
			"-cp",
			"tests/compiler",
			"-cp",
			"tests/runtime",
			"-cp",
			"tests/tooling",
			"--run",
			main
		];
	}

	static function resolveArguments(root:String, output:String, arguments:Array<String>):Array<String> {
		return [
			for (argument in arguments)
				argument.split("{root}").join(root).split("{output}").join(output)
		];
	}

	static function runProgram(root:String, test:ProgramCase):Bool {
		var haxe = Path.join([root, ".tools", "haxe", "haxe"]);
		var hl = Path.join([root, "vendor", "hashlink", "hl"]);
		var source = Path.join([root, "tests", "programs", test.name + ".hx"]);
		var output = Path.join([root, "out", test.name + ".hl"]);
		var compileStatus = Sys.command(haxe, ["--cwd", root, "-cp", "src", "--run", "Main", source, output]);
		if (compileStatus != 0) {
			Sys.stderr().writeString('FAIL: ${test.name} failed to compile\n');
			return false;
		}
		var status = Sys.command(hl, [output]);
		if (status != test.expectedExit) {
			Sys.stderr().writeString('FAIL: ${test.name} expected exit ${test.expectedExit}, got $status\n');
			return false;
		}
		Sys.println('PASS: ${test.name} source compiled and executed (exit ${test.expectedExit})');
		return true;
	}

	static function loadPrograms(root:String):Array<ProgramCase> {
		var path = Path.join([root, "tests", "programs", "expected-exits.tsv"]);
		var result = [];
		var seen = new Map<String, Bool>();
		for (line in File.getContent(path).split("\n")) {
			line = StringTools.trim(line);
			if (line == "" || StringTools.startsWith(line, "#"))
				continue;
			var fields = line.split("\t");
			if (fields.length != 2)
				throw 'Invalid program manifest row: $line';
			var name = fields[0];
			var expectedExit = Std.parseInt(fields[1]);
			if (expectedExit == null)
				throw 'Invalid expected exit code for $name';
			if (seen.exists(name))
				throw 'Duplicate program manifest entry: $name';
			seen.set(name, true);
			result.push({name: name, expectedExit: expectedExit});
		}
		return result;
	}

	static function validateProgramManifest(root:String, programs:Array<ProgramCase>):Void {
		var expected = new Map<String, Bool>();
		for (test in programs)
			expected.set(test.name + ".hx", true);
		var directory = Path.join([root, "tests", "programs"]);
		for (file in FileSystem.readDirectory(directory)) {
			if (!StringTools.endsWith(file, ".hx") || StringTools.startsWith(file, "utest-"))
				continue;
			if (!expected.exists(file))
				throw 'Program fixture is missing from expected-exits.tsv: $file';
		}
		for (file in expected.keys())
			if (!FileSystem.exists(Path.join([directory, file])))
				throw 'Program manifest references missing fixture: $file';
	}

	static function matches(options:DriverOptions, suite:String, name:String):Bool {
		if (options.suites.indexOf("all") == -1 && options.suites.indexOf(suite) == -1)
			return false;
		return options.filter == null || options.filter.match(name);
	}

	static function parseOptions(args:Array<String>):DriverOptions {
		var root = Sys.getCwd();
		var suites = ["all"];
		var filter:Null<EReg> = null;
		var listOnly = false;
		var index = 0;
		while (index < args.length) {
			switch args[index++] {
				case "--root":
					if (index == args.length)
						throw "--root requires a path";
					root = args[index++];
				case "--suite":
					if (index == args.length)
						throw "--suite requires a name";
					suites = args[index++].split(",");
				case "--test":
					if (index == args.length)
						throw "--test requires a regular expression";
					filter = new EReg(args[index++], "i");
				case "--list":
					listOnly = true;
				case argument:
					throw 'Unknown test driver argument: $argument';
			}
		}
		return {
			root: FileSystem.fullPath(root),
			suites: suites,
			filter: filter,
			listOnly: listOnly
		};
	}
}
