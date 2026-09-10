package driver;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

typedef NamedCase = {
	var suite:String;
	var name:String;
}

typedef ProgramCase = {
	var name:String;
	var expectedExit:Int;
}

enum CompileStep {
	HaxeMain(main:String, arguments:Array<String>);
	Hxml(path:String);
}

typedef ExecutableCase = {
	var suite:String;
	var name:String;
	var compile:CompileStep;
	var output:String;
	var runtimeArguments:Array<String>;
	var expectedExit:Null<Int>;
	var message:String;
}

class TestCatalog {
	static final compilerMains = [
		"TestMain",
		"AuditVerifierMain",
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
		"CHeaderImporterMain",
		"HxiAuditMain",
		"HxiParserMain",
		"HxiAbiMain",
	];

	static final toolingMains = ["LanguageServiceMain", "ProtocolMain", "LspProtocolMain", "UtestDiscoveryMain"];
	static final runtimeMains = ["RuntimeDomainMain"];

	public static function namedCases():Array<NamedCase> {
		var result = [];
		for (name in compilerMains)
			result.push({suite: "compiler", name: name});
		for (name in toolingMains)
			result.push({suite: "tooling", name: name});
		for (name in runtimeMains)
			result.push({suite: "runtime", name: name});
		return result;
	}

	public static function customCases():Array<NamedCase> {
		return [{suite: "tooling", name: "pos-infos"}];
	}

	public static function executableCases():Array<ExecutableCase> {
		return [
			hxmlCase("runtime", "patch-opcodes", "tests/hxml/patch-opcodes-test.hxml", "patch-opcodes-test.hl", 0,
				"compiler opcode coverage and malformed patch rejection"),
			mainCase("runtime", "exceptions", "ExceptionMain", "exception.hl", 42, "exceptions can be chained, thrown, caught, and inspected"),
			mainCase("runtime", "ereg", "ERegMain", "ereg.hl", 42, "regex literals and EReg operations executed"),
			mainCase("runtime", "list", "ListMain", "list.hl", 42, "Array-backed List insertion and iteration executed"),
			mainCase("runtime", "array-splice", "ArraySpliceMain", "array-splice.hl", 42, "Array.splice mutation and removed values executed"),
			mainCase("runtime", "reflect-methods", "ReflectMethodsMain", "reflect-methods.hl", 42,
				"Reflect.compareMethods preserves static and bound method identity"),
			mainCase("runtime", "null-reference", "NullReferenceMain", "null-reference.hl", 42,
				"null coerces to reference-like types while primitives remain strict"),
			mainCase("runtime", "stdlib", "StdlibMain", "stdlib.hl", 42, "vendored stdlib compiled and executed"),
			mainCase("runtime", "bytes-view", "BytesViewMain", "bytes-view.hl", 42, "managed byte views alias their source"),
			mainCase("runtime", "language-features", "LanguageFeaturesMain", "language-features.hl", 42,
				"self-hosted FFI language constructs compiled and executed"),
			mainCase("runtime", "json", "JsonMain", "json.hl", 42, "JSON parsing, printing, reflection, Unicode, and rejection executed"),
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

	public static function loadPrograms(root:String):Array<ProgramCase> {
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
		validateProgramManifest(root, result);
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
}
