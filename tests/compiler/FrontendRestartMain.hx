import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/**
 * A module found only while typing restarts the whole frontend, so the restarts a compile does are reported. A
 * Dynamic object literal does not cause one on HashLink, whose dynamic objects are native; arithmetic on a Dynamic
 * operand still does, and names the function that needed the runtime module.
 */
class FrontendRestartMain {
	static function main():Void {
		var literal = compile("function keep(value:Dynamic):Void {} function main():Int { keep({count: 42}); return 42; }");
		if (literal.length != 0)
			throw 'A Dynamic object literal restarted the frontend: $literal';
		var arithmetic = compile("function read(value:Dynamic):Int return value < 0 ? 0 : 42; function main():Int return read(1);");
		if (arithmetic.length != 1 || arithmetic[0].indexOf("read needs haxeon.DynamicOps") < 0)
			throw 'Dynamic arithmetic must restart once and say why: $arithmetic';
		Sys.println("PASS: frontend restarts are reported, and Dynamic object literals do not cause one on HashLink");
	}

	static function compile(source:String):Array<String> {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", source);
		return compiler.compile("Main").metrics.frontendRestarts;
	}
}
