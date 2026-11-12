import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;

/** Folding a checked abstract constant must retain its semantic type without opening the abstract to raw values. */
class InlineEnumAbstractConstantMain {
	static function mode(value:Int):String
		return 'enum abstract Mode(Int) to Int {var Active = $value; var Inactive = 7;}';

	static function checkIncremental(indexed:Bool):Void {
		var compiler = new Compiler();
		compiler.update("Mode.hx", mode(41));
		var constants = 'import Mode; class Constants {public static inline var ACTIVE:Mode = Mode.Active; public static inline var ALIAS:Mode = ACTIVE;}';
		compiler.update("Constants.hx", constants);
		compiler.update("Api.hx", 'import Mode; import Constants; function read(value:Mode = Constants.ALIAS):Int return value;');
		compiler.update("Main.hx", 'import Api; function main():Int return Api.read();');
		if (new IrInterpreter(compiler.compile("Main", null, indexed).ir).run("main") != 41)
			throw "The folded enum abstract constant lost its initial value";
		compiler.update("Mode.hx", mode(42));
		var changed = compiler.compile("Main", null, indexed);
		if (changed.retyped.indexOf("main") < 0 || new IrInterpreter(changed.ir).run("main") != 42)
			throw "An enum abstract edit left a stale inline alias or default argument";
		compiler.update("Constants.hx", constants.split("Mode.Active").join("Mode.Inactive"));
		var aliased = compiler.compile("Main", null, indexed);
		if (aliased.retyped.indexOf("main") < 0 || new IrInterpreter(aliased.ir).run("main") != 7)
			throw "An inline initializer edit left a stale cached alias or default argument";
		if (compiler.compile("Main", null, indexed).retyped.length != 0)
			throw "An unchanged enum abstract constant caused retyping";
	}

	static function reject(declarations:String, initializer:String, message:String):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", declarations + ' class Constants {public static inline var VALUE:Mode = $initializer;} function main():Int return 0;');
		try {
			compiler.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1002" || error.diagnostic.message.indexOf(message) < 0)
				throw error;
			return;
		}
		throw "An invalid inline constant was accepted";
	}

	static function main():Void {
		for (indexed in [false, true])
			checkIncremental(indexed);
		reject(mode(42), "42", "Type mismatch");
		reject('enum abstract Mode(String) {var Active = "ready";}', '"ready"', "Type mismatch");
		reject(mode(42) + ' enum abstract Other(Int) {var Active = 42;}', "Other.Active", "Type mismatch");
		reject(mode(42) + ' function make():Mode return Mode.Active;', "make()", "compile-time constant");
		Sys.println("PASS: inline enum abstract constants preserve closed types and invalidate aliases and defaults");
	}
}
