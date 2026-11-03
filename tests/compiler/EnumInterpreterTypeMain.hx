import compiler.Frontend;
import compiler.ir.IrInterpreter;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.SourceProvenance.Located;

class EnumInterpreterTypeMain {
	static function main():Void {
		var source = 'enum First { Item(value:Int); } enum Second { Item(value:Int); } '
			+ 'function main():Int { var value:Dynamic = First.Item(1); '
			+ 'return Std.isOfType(value, First) && !Std.isOfType(value, Second) ? 42 : 1; }';
		var program = Frontend.compile(source);
		if (new IrInterpreter(program).run("main") != 42)
			throw "The IR interpreter did not recognize the concrete enum type";
		var changed = false;
		for (fn in program.functions) for (block in fn.blocks) for (index in 0...block.instructions.length) {
			var instruction = block.instructions[index];
			switch instruction.value {
				case Call(out, "__std_is_of_type", args):
					block.instructions[index] = new Located(Call(out, "__std_is_exact_type", args), instruction.provenance);
					changed = true;
				default:
			}
		}
		if (!changed || new IrInterpreter(program).run("main") != 42)
			throw "The IR interpreter did not recognize the exact enum type";
		Sys.println("PASS: enum values retain their type in the IR interpreter");
	}
}
