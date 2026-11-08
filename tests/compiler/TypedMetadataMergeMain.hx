import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A rebuild in a reused compiler session keeps what unchanged callers still use, and nothing else. `Promise<T>` reaches
 * the generic enum `Outcome<T>` through `Future<T>`, so each instantiation has an owner class of its own. `Maker` makes the
 * specialization `Promise<Array<String>>`; `Binder` takes a bound method of it, which erasure resolves through the owner
 * object and its `cancel` method; `Other` keeps `Promise<Int>` in the program when the other module goes away; `Main` uses all, reads a code identity (so the generated identity table is part of the
 * program) and needs a runtime module found only while typing, so the first compile restarts the frontend.
 *
 * Every scenario edits the sources after a first compile, reads every loaded module from disk again as a reused session
 * does, compiles again, and then compiles the final sources in a fresh compiler. The program must run alike, and the
 * specialized owners (with their fields and methods), the specialized enums and the generic owner aliases must be the
 * same: an incremental result equals a from-scratch one, so nothing is lost and nothing piles up.
 */
class TypedMetadataMergeMain {
	static final outcomeSource = "enum Outcome<T> { Success(value:T); Cancelled; }";
	static final futureSource = "class Future<T> { var outcome:Null<Outcome<T>>; public function new() {} public function finish(result:Outcome<T>):Void { outcome = result; } }";
	static final promiseSource = "class Promise<T> { public final future:Future<T>; public function new() future = new Future<T>(); public function cancel():Void future.finish(Cancelled); }";
	static final makerSource = "class Maker { public static function make():Promise<Array<String>> return new Promise<Array<String>>(); }";
	static final otherSource = "class Other { public static function make():Promise<Int> return new Promise<Int>(); }";
	static final binderSource = "class Binder { public static function bind(promise:Promise<Array<String>>):Void->Void return promise.cancel; }";
	static final mainSource = "class Main { static function read(value:Dynamic):Int return value < 0 ? 0 : 42; static function main():Int { Other.make().cancel(); Binder.bind(Maker.make())(); return haxeon.build.CodeIdentity.ofModule('Main') == null ? 1 : read(1); } }";
	static final mainWithoutPromiseSource = "class Main { static function read(value:Dynamic):Int return value < 0 ? 0 : 42; static function main():Int { Other.make().cancel(); return haxeon.build.CodeIdentity.ofModule('Main') == null ? 1 : read(1); } }";

	static function main():Void {
		var failures:Array<String> = [];
		attempt(failures, "second compile without an edit", files -> {});
		attempt(failures, "after editing the entry module", files -> files.set("Main.hx", mainSource + " "));
		attempt(failures, "after editing the module that makes the specialization", files -> files.set("Maker.hx", makerSource + " "));
		attempt(failures, "after editing the module that binds the method", files -> files.set("Binder.hx", binderSource + " "));
		attempt(failures, "after editing the generic class", files -> files.set("Promise.hx", promiseSource + " "));
		attempt(failures, "after giving the generic class a method",
			files -> files.set("Promise.hx",
				StringTools.replace(promiseSource, "public function cancel()",
					"public function again():Void future.finish(Cancelled); public function cancel()")));
		attempt(failures, "after adding a module", files -> {
			files.set("Extra.hx", "class Extra { public static function value():Int return 1; }");
			files.set("Main.hx", StringTools.replace(mainSource, "read(1)", "read(1) + Extra.value() - 1"));
		});
		attempt(failures, "after removing the modules that make and bind the specialization", files -> {
			files.remove("Maker.hx");
			files.remove("Binder.hx");
			files.set("Main.hx", mainWithoutPromiseSource);
		});
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: typed metadata of unchanged modules is kept, and an incremental compile equals a from-scratch one");
	}

	static function initialSources():Map<String, String>
		return [
			"Outcome.hx" => outcomeSource,
			"Future.hx" => futureSource,
			"Promise.hx" => promiseSource,
			"Maker.hx" => makerSource,
			"Other.hx" => otherSource,
			"Binder.hx" => binderSource,
			"Main.hx" => mainSource
		];

	static function attempt(failures:Array<String>, label:String, change:Map<String, String>->Void):Void {
		try {
			var files = initialSources(), compiler = newCompiler(files);
			expectExitCode(compiler, "first compile");
			var before = [for (path in files.keys()) path];
			change(files);
			for (path => text in files)
				compiler.update(path, text);
			for (path in before)
				if (!files.exists(path))
					compiler.remove(path);
			readLoadedModulesAgain(compiler);
			expectExitCode(compiler, "second compile");
			var fresh = newCompiler(files);
			expectExitCode(fresh, "fresh compile");
			var incremental = describeSpecializations(compiler),
				scratch = describeSpecializations(fresh);
			if (incremental != scratch)
				throw 'specializations differ from a fresh compile\nincremental:\n$incremental\nfresh:\n$scratch';
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}

	static function newCompiler(files:Map<String, String>):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}

	static function expectExitCode(compiler:Compiler, step:String):Void {
		if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
			throw '$step changed behavior';
	}

	static function readLoadedModulesAgain(compiler:Compiler):Void {
		for (name => state in compiler.modules) {
			var path = state.source.path;
			if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path))
				compiler.refreshLoadedSource(name, sys.io.File.getContent(path));
		}
	}

	/** The specialized owner classes with their fields and methods, the specialized enums and the owner aliases, sorted. */
	static function describeSpecializations(compiler:Compiler):String {
		var program = compiler.lastTypedProgram, lines:Array<String> = [];
		if (program == null)
			throw "no typed program";
		for (entry in program.classes)
			if (entry.specializationOrigin != null)
				lines.push('class ${entry.name} fields=${[for (field in entry.fields) field.name].join(",")} methods=${[for (method in entry.methods) method.name].join(",")}');
		for (entry in program.enums)
			if (entry.specializationOrigin != null)
				lines.push('enum ${entry.name} cases=${[for (enumCase in entry.cases) enumCase.name].join(",")}');
		for (signature => owner in program.genericOwnerAliases)
			lines.push('alias $signature=$owner');
		lines.sort(Reflect.compare);
		return lines.join("\n");
	}
}
