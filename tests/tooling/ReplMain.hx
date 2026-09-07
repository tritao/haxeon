import compiler.Compiler;
import compiler.service.Repl;
import runtime.Runtime;

class ReplMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Math.hx", "function add(a:Int, b:Int):Int { return a + b; }");
		compiler.update("Main.hx", "function main():Int { return 0; }");
		compiler.compile("Main");
		var program = new Repl(compiler).compileInt("Math.add(20, 22)"),
			loaded = Runtime.load(program.bytes, program.identity);
		if (Runtime.callInt(loaded, program.stableId) != 42)
			throw "REPL expression returned the wrong result";
		Runtime.dispose(loaded);
		if (compiler.modules.exists("__repl__"))
			throw "REPL compilation mutated the live compiler modules";
		Sys.println("PASS: compiler-backed integer REPL expression executed");
	}
}
