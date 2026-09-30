import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;

/**
 * A string literal allocates a String object each time it is evaluated, so IrStringLiterals evaluates each literal once per
 * call: at the nearest block dominating all its definitions, or the entry block when that block is in a loop.
 */
class StringLiteralsMain {
	static function main():Void {
		var program = Frontend.compile("function inLoop(n:Int):Int { var t = 0; for (i in 0...n) { if (\"go\" == \"go\") t += 1; } return t; } "
			+ "function repeated(flag:Bool):String { if (flag) return \"same\"; return \"same\"; } "
			+ "function onePath(flag:Bool):String { if (flag) return \"only\"; return \"\"; } "
			+ "function twice(a:String):Bool { return a == \"x\" || a == \"x\" || a == \"y\"; } "
			+ "function loopThrow(n:Int):Int { var t = 0; for (i in 0...n) { if (i > 100) throw \"big\"; t += i; } return t; } "
			+ "function main():Int return inLoop(3) + repeated(true).length + onePath(true).length + (twice(\"y\") ? 1 : 0) + loopThrow(3);");
		IrVerifier.verify(program);
		var inLoop = find(program, "inLoop");
		expect(definitions(inLoop, "go") == 1, "a literal evaluated in a loop body should be defined once, not per evaluation");
		expect(blockOf(inLoop, "go") == 0, "a literal in a loop should be defined in the entry block, outside the loop");
		expect(definitions(find(program, "repeated"), "same") == 1, "a literal defined on two paths should be defined once");
		var onePath = find(program, "onePath");
		expect(definitions(onePath, "only") == 1, "a literal defined once is kept");
		expect(blockOf(onePath, "only") != 0, "a literal on one path must stay on that path so the other path does not allocate it");
		expect(definitions(find(program, "twice"), "x") == 1, "the same literal evaluated twice in one function is defined once");
		expect(definitions(find(program, "twice"), "y") == 1, "a different literal is left alone");
		expect(definitions(find(program, "loopThrow"), "big") == 1, "a literal thrown from a loop is defined once");
		Sys.println("PASS: string literals are evaluated once per call");
	}

	static function find(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Missing function $name';
	}

	static function definitions(fn:IrFunction, literal:String):Int {
		var count = 0;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case ConstString(_, value) if (value == literal):
						count++;
					default:
				}
		return count;
	}

	/** Index, in the function's block list, of the first block defining the literal. */
	static function blockOf(fn:IrFunction, literal:String):Int {
		for (index in 0...fn.blocks.length)
			for (located in fn.blocks[index].instructions)
				switch located.value {
					case ConstString(_, value) if (value == literal):
						return index;
					default:
				}
		return -1;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
