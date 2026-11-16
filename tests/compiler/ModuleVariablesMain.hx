using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.Frontend;
import compiler.core.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import runtime.Runtime;

/**
 * Module-level `var` and `final` (tests/programs/module-level-variables.hx runs the rest): a final is never assigned, from its
 * module or another; initializers run in dependency order across modules; a field needs a type or an initializer that gives
 * one; and the module-less Frontend refuses them instead of dropping them.
 */
class ModuleVariablesMain {
	static function main():Void {
		expectValue("initializers in dependency order across modules", [
			"Provider.hx" => "var value = 40;",
			"Main.hx" => "import Provider; final value = Provider.value + 2; function main():Int return value;"
		], 42);
		expectValue("a module-level variable written and read across modules", [
			"Store.hx" => "var count = 0; function bump():Void count += 2;",
			"Main.hx" => "import Store; function main():Int { Store.bump(); Store.count += 40; return Store.count; }"
		], 42);
		expectError("a final assigned in its module",
			["Main.hx" => "final limit = 1; function main():Int { limit = 2; return limit; }"],
			"E1026");
		expectError("a final incremented from another module", [
			"Limits.hx" => "final limit = 1;",
			"Main.hx" => "import Limits; function main():Int { Limits.limit++; return 0; }"
		], "E1026");
		expectError("a variable with neither type nor initializer",
			["Main.hx" => "var x; function main():Int return 0;"], null);
		expectError("an empty array initializer with no type",
			["Main.hx" => "var x = []; function main():Int return 0;"],
			null);
		try {
			Frontend.compile("var x = 1; function main():Int return x;");
			throw "Frontend compiled a module-level variable it has no module for";
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf("need a module") < 0)
				throw 'Frontend refused a module-level variable with: ${error.diagnostic.format()}';
		}
		Sys.println("PASS: module-level variables are typed, ordered and enforced as static fields of their module");
	}

	static function compiled(sources:Map<String, String>):Compiler {
		var compiler = new Compiler();
		for (path => source in sources)
			compiler.update(path, source);
		return compiler;
	}

	static function expectValue(label:String, sources:Map<String, String>, expected:Int):Void {
		var result = try compiled(sources).compile("Main") catch (error:CompileError)
			throw '$label failed to compile: ${error.diagnostic.format()}',
			build = result.artifact.hashLink(),
			live = Runtime.load(HlWriter.encode(build.module).flatten(), build.runtimeIdentity),
			value = Runtime.callInt(live, build.functionIds.get("main"));
		Runtime.dispose(live);
		if (value != expected)
			throw '$label: main returned $value instead of $expected';
	}

	/** `code` null: any diagnostic. */
	static function expectError(label:String, sources:Map<String, String>, code:Null<String>):Void {
		try {
			compiled(sources).compile("Main");
		} catch (error:CompileError) {
			if (code != null && error.diagnostic.code != code)
				throw '$label failed with ${error.diagnostic.code} instead of $code: ${error.diagnostic.format()}';
			return;
		}
		throw '$label compiled';
	}
}
