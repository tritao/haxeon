import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

class PrimitiveStringEffectsMain {
	static final helpers = 'class Support { public static var view:View; public static function measure(text:String):Int { '
		+ 'var lower = text.toLowerCase(), index = lower.indexOf("x"); return index < 0 ? 1 : 2; } }';
	static final view = 'class Box { public var entries:Array<Int> = [1, 2]; public function new() {} } '
		+ 'class View { public var provider:Null<Box>; var lines:Array<String> = ["x"]; var query(get, never):String; '
		+ 'function get_query():String return lines.join(""); public function new() { provider = new Box(); Support.view = this; } '
		+ 'public function run():Int { if (provider == null) return 0; var total = 0; for (i in 0...provider.entries.length) { '
		+ 'var entry = provider.entries[i]; total += Support.measure(query); } return total; } } '
		+ 'function main():Int return new View().run();';

	static function compiler():Compiler {
		var result = new Compiler(null, CompilerIntrinsics.configuration());
		result.addSourceRoot(Sys.getCwd() + "/stdlib");
		result.update("Support.hx", helpers);
		result.update("Main.hx", view);
		return result;
	}

	static function rejected(result:Compiler):Bool {
		try
			result.compile("Main")
		catch (error:CompileError) {
			if (error.diagnostic.code != "E1005")
				throw error;
			return true;
		}
		return false;
	}

	static function main():Void {
		var result = compiler();
		var compiled = result.compile("Main");
		var value = GeneratedProgramRunner.exitCode(compiled);
		if (value != 4)
			throw "primitive string helper or getter returned " + value;
		var impure = StringTools.replace(helpers, "var lower", "view.provider = null; var lower");
		result.update("Support.hx", impure);
		if (!rejected(result))
			throw "incremental compile kept a field fact after the helper gained an effect";
		var fresh = compiler();
		fresh.update("Support.hx", impure);
		if (!rejected(fresh))
			throw "cold compile accepted the mutated field";
		result.update("Support.hx", helpers);
		result.compile("Main");
		Sys.println("PASS: primitive string and getter effects, runtime behavior, and incremental purity invalidation");
	}
}
