import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrDeadPureValues;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
import compiler.ir.codec.IrFunctionStateCodec;

class DeadPureValuesMain {
	static function expect(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Void {
		var b = new IrBuilder(), input = b.argument("x", I32);
		var dead = b.add(b.constInt(2), b.constInt(3));
		b.mul(dead, b.constInt(4));
		var debug = b.constInt(7), zero = b.constInt(0);
		b.div(input, zero); // Division may trap even if its result is unused.
		b.call("effect", [input], I32); // Calls remain observable.
		b.returnValue(input);
		var binding:IrDebugBinding = {identity: "debug", name: "debug", value: debug, path: "test.hx", scopeStart: 0, scopeEnd: 1};
		var fn = new IrFunction("test", b.arguments, I32, b.blocks, [binding]);
		var before = IrFunctionStateCodec.encode(fn), result = IrDeadPureValues.run(fn);
		expect(before.compare(IrFunctionStateCodec.encode(fn)) == 0, "input was mutated");
		expect(result.blocks[0].instructions.length == 4, "dead chain removed, debug value, divisor, division and call retained");
		expect(result.debugBindings[0].value == debug, "debug value remains defined");
		expect(IrDeadPureValues.run(result) == result, "unchanged result retains identity");

		b = new IrBuilder();
		var condition = b.argument("condition", Bool), left = b.createBlock(), right = b.createBlock(), merge = b.createBlock();
		b.branch(condition, left, right);
		b.select(left); var a = b.constInt(40); b.jump(merge);
		b.select(right); var c = b.constInt(41); b.jump(merge);
		b.select(merge); var chosen = b.phi(I32, [{block: left.id, value: a}, {block: right.id, value: c}]);
		b.returnValue(b.add(chosen, b.constInt(2)));
		fn = new IrFunction("main", b.arguments, I32, b.blocks);
		var program = new IrProgram("main"); program.functions = [IrDeadPureValues.run(fn)];
		IrVerifier.verify(program);
		var interpreter = new IrInterpreter(program);
		expect(interpreter.run("main", [true]) == 42 && interpreter.run("main", [false]) == 43, "phi operands survive on both edges");
		Sys.println("PASS: dead pure values preserve effects, debug bindings and live phi inputs");
	}
}
