import compiler.Frontend;
import compiler.hl.HlFunction;
import compiler.hl.incremental.HlSymbolTable;
import compiler.hl.incremental.HlLoweredCache;
import compiler.hl.incremental.HlLoweredFunction;
import compiler.ir.hl.HlLower;

/**
 * HAXEON_CHECK_REUSE=1 lowers every function a live build keeps again and compares it with the kept one. This shows the check can
 * fail: a kept entry with one operand changed must be reported by name, and the same entries unchanged must pass.
 */
class LiveKeptCheckMain {
	static function main():Void {
		checkOpcodeComparison();
		var program = Frontend.compile("function value():Int return 7; function main():Int return value() + 1;");
		var layout:Map<String, Int> = [];
		HlLower.lower(program, layout);
		var symbols = new HlSymbolTable(), cache = new HlLoweredCache();
		HlLower.lowerStableMeasured(program, symbols, layout, null, [], null, null, 0, true, false, cache, false, true);
		Sys.putEnv("HAXEON_CHECK_REUSE", "1");
		HlLower.lowerStableMeasured(program, symbols, layout, null, [], null, null, 0, true, false, cache, false, true);
		Sys.println("PASS: kept functions lower to the same code again");
		var entry = cache.entries.get("value");
		if (entry == null)
			throw "missing entry";
		var opcodes = entry.fn.opcodes.copy(), mutated = false;
		for (index in 0...opcodes.length)
			switch opcodes[index] {
				case LoadInt(destination, constant) if (!mutated):
					opcodes[index] = LoadInt(destination, constant + 1);
					mutated = true;
				default:
			}
		if (!mutated)
			throw "no integer load to change in value()";
		var wrong = new HlFunction(entry.fn.type, entry.fn.functionIndex, entry.fn.registers, opcodes, entry.fn.debugLocations, entry.fn.debugAssignments);
		cache.entries.set("value", new HlLoweredFunction("value", entry.source, wrong, [], []));
		var message:Null<String> = null;
		try
			HlLower.lowerStableMeasured(program, symbols, layout, null, [], null, null, 0, true, false, cache, false, true)
		catch (error:Dynamic)
			message = Std.string(error);
		if (message == null || message.indexOf("kept function value") < 0 || message.indexOf("opcode") < 0)
			throw 'a wrong kept opcode must be reported by name, got: $message';
		Sys.println("PASS: a wrong kept function is reported by name");
	}
	static function checkOpcodeComparison():Void {
		var left:Array<HlInstruction> = [Jump("a"), Label("a"), CallN(0, 3, [1, 2]), LoadBool(0, true)];
		var right:Array<HlInstruction> = [Jump("renamed"), Label("renamed"), CallN(0, 3, [1, 2]), LoadBool(0, true)];
		var functionOf = function(ops:Array<HlInstruction>) return new HlFunction(0, 0, [], ops);
		var compare = function(ops:Array<HlInstruction>) return compiler.hl.HlFunctionEquality.difference(functionOf(left), functionOf(ops));
		if (compare(right) != null)
			throw "Equivalent labels and copied register arrays must compare equal";
		right[2] = CallN(0, 3, [1, 4]);
		if (compare(right) == null)
			throw "A changed array operand must compare unequal";
		right[2] = CallN(0, 3, [1, 2]);
		right[1] = Label("other");
		if (compare(right) == null)
			throw "Label renaming must be consistent";
		right[1] = Label("renamed");
		right[3] = LoadBool(0, false);
		if (compare(right) == null)
			throw "A changed boolean operand must compare unequal";
		right[3] = LoadInt(0, 1);
		if (compare(right) == null)
			throw "Different constructors must compare unequal";
		if (compiler.hl.HlFunctionEquality.difference(functionOf([Label("a"), Label("b")]),
			functionOf([Label("same"), Label("same")])) == null)
			throw "Label renaming must be one-to-one";
		Sys.println("PASS: typed opcode comparison preserves operands and label bijections");
	}

}
