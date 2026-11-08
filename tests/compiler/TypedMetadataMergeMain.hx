import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A rebuild in a reused compiler session keeps what unchanged callers still use. `Promise<T>` reaches the generic enum
 * `Outcome<T>` through `Future<T>`, so each instantiation has an owner class of its own. `Maker` makes the specialization
 * `Promise<Array<String>>`; `Binder` takes a bound method of it, which erasure resolves through the specialization's owner
 * object and its `cancel` method; `Main` uses both, reads a code identity (so the generated identity table is part of
 * the program) and needs a runtime module found only while typing, so the first compile restarts the frontend.
 * Before the second compile every loaded module is read from disk again, as a reused session does.
 */
class TypedMetadataMergeMain {
	static final outcomeSource = "enum Outcome<T> { Success(value:T); Cancelled; }";
	static final futureSource = "class Future<T> { var outcome:Null<Outcome<T>>; public function new() {} public function finish(result:Outcome<T>):Void { outcome = result; } }";
	static final promiseSource = "class Promise<T> { public final future:Future<T>; public function new() future = new Future<T>(); public function cancel():Void future.finish(Cancelled); }";
	static final makerSource = "class Maker { public static function make():Promise<Array<String>> return new Promise<Array<String>>(); }";
	static final binderSource = "class Binder { public static function bind(promise:Promise<Array<String>>):Void->Void return promise.cancel; }";
	static final mainSource = "class Main { static function read(value:Dynamic):Int return value < 0 ? 0 : 42; static function main():Int { Binder.bind(Maker.make())(); return haxeon.build.CodeIdentity.ofModule('Main') == null ? 1 : read(1); } }";

	static function main():Void {
		var failures:Array<String> = [];
		attempt(failures, "second compile without an edit", c -> {});
		attempt(failures, "after editing the module that makes the specialization", c -> c.update("Maker.hx", makerSource + " "));
		attempt(failures, "after editing the module that binds the method", c -> c.update("Binder.hx", binderSource + " "));
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println("PASS: typed metadata merges across compiles");
	}

	static function readLoadedModulesAgain(compiler:Compiler):Void {
		for (name => state in compiler.modules) {
			var path = state.source.path;
			if (sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path))
				compiler.refreshLoadedSource(name, sys.io.File.getContent(path));
		}
	}

	static function attempt(failures:Array<String>, label:String, change:Compiler->Void):Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update("Outcome.hx", outcomeSource);
		compiler.update("Future.hx", futureSource);
		compiler.update("Promise.hx", promiseSource);
		compiler.update("Maker.hx", makerSource);
		compiler.update("Binder.hx", binderSource);
		compiler.update("Main.hx", mainSource);
		try {
			if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
				throw "first compile changed behavior";
			change(compiler);
			readLoadedModulesAgain(compiler);
			if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
				throw "second compile changed behavior";
		} catch (error:Dynamic) {
			failures.push('$label: ${Std.string(error)}');
		}
	}
}
