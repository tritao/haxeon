import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.ir.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;

/** A write through one name invalidates refinements of the same field through aliases. */
class FieldAliasFlowMain {
	static function main():Void {
		var compiler = new Compiler(), source = 'class Cell { public var item:Null<Int>; public var keep:Null<Int>; '
			+ 'public function new() { item=null; keep=9; } } '
			+ 'function main():Int { var first=new Cell(); var alias=first; first.item=null; first.keep=9; alias.item=41; '
			+ 'return first.item == null ? 0 : first.item + first.keep; }';
		for (expected in [50, 51, 50]) {
			compiler.update("Main.hx", expected == 51 ? StringTools.replace(source, "alias.item=41", "alias.item=42") : source);
			var compiled = compiler.compile("Main"), interpreted = new IrInterpreter(compiled.ir).run("main"),
				native = GeneratedProgramRunner.exitCode(compiled);
			if (interpreted != expected || native != expected)
				throw 'field alias flow expected $expected, interpreter=$interpreted, HashLink=$native';
		}
		var dynamicCompiler = new Compiler();
		CompilerIntrinsics.register(dynamicCompiler);
		dynamicCompiler.addSourceRoot("stdlib");
		dynamicCompiler.update("Main.hx", 'class Cell { public var item:Null<Int>; public function new() item=null; } '
			+ 'function main():Int { var first=new Cell(); var alias:Dynamic=first; first.item=null; alias.item=42; '
			+ 'return first.item == null ? 0 : first.item; }');
		var dynamicResult = GeneratedProgramRunner.exitCode(dynamicCompiler.compile("Main"));
		if (dynamicResult != 42) throw 'Dynamic field alias returned $dynamicResult';
		var setter = new Compiler();
		setter.update("Main.hx", 'class Cell { public var item:Null<Int>; public var trigger(get,set):Int; '
			+ 'public function new() item=1; function get_trigger():Int return 0; function set_trigger(v:Int):Int { item=null; return v; } } '
			+ 'function main():Int { var cell=new Cell(); if (cell.item != null) { cell.trigger=1; return cell.item + 1; } return 0; }');
		var rejected = false;
		try setter.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1010";
		if (!rejected) throw "property setter preserved a field refinement across its side effects";
		Sys.println("PASS: field writes invalidate alias refinements through incremental edits");
	}
}
