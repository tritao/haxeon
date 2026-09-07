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

	static final toolingMains = ["LanguageServiceMain", "ProtocolMain", "LspProtocolMain"];
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
