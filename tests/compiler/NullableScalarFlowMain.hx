import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrInterpreter;
import compiler.ir.IrNullableScalarFlow;
import compiler.ir.IrVerifier;

class NullableScalarFlowMain {
	static function main():Void {
		var program = Frontend.compile('function identity(value:Null<Int>):Int return value == null ? 7 : value; '
			+ 'function forward(value:Null<Int>):Int return identity(value); '
			+ 'function choose(flag:Bool):Int { var value:Null<Int> = flag ? 42 : null; return forward(value); } '
			+ 'function escape(value:Int):Dynamic { var optional:Null<Int> = value; return optional; } '
			+ 'function main():Int return choose(true);');
		var before = new IrInterpreter(program);
		if (before.run("choose", [true]) != 42 || before.run("choose", [false]) != 7 || before.run("escape", [13]) != 13)
			throw "Unexpected nullable scalar baseline";
		IrNullableScalarFlow.rewrite(program);
		IrVerifier.verify(program);
		var after = new IrInterpreter(program), choose = find(program, "choose"), escape = find(program, "escape");
		if (after.run("choose", [true]) != 42 || after.run("choose", [false]) != 7 || after.run("escape", [13]) != 13)
			throw "Nullable scalar control flow changed";
		var chooseBoxes = countBoxes(choose), escapeBoxes = countBoxes(escape);
		if (chooseBoxes != 0 || escapeBoxes != 1)
			throw 'Expected scalar components for local values and a box at the dynamic escape, got $chooseBoxes and $escapeBoxes';
		find(program, "$nullable-scalar:arguments:forward");
		find(program, "$nullable-scalar:arguments:identity");
		Sys.println("PASS: nullable scalar joins stay unboxed and dynamic escapes retain their box");
	}

	static function find(program:IrProgram, name:String):compiler.ir.IrFunction {
		for (fn in program.functions) if (fn.name == name) return fn;
		throw 'Missing function $name';
	}

	static function countBoxes(fn:compiler.ir.IrFunction):Int {
		var count = 0;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case ToDyn(out, value) if (Type.enumEq(out.type, Nullable(I32)) && value.type == I32): count++;
			default:
		}
		return count;
	}
}
