import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.cleanup.IrDeadPureValues;
import compiler.ir.tools.IrInterpreter;
import compiler.ir.verify.IrVerifier;

class DeadPureValuesMain {
	/** The pass on `fn`'s body: `fn` itself when it changes nothing, else the edited body decoded. */
	static function removeDeadValues(fn:IrFunction):IrFunction {
		var body = compiler.ir.model.IrBodyBuilder.encode(fn);
		return IrDeadPureValues.runBody(body, new compiler.ir.model.IrPassScratch()) ? body.toFunction() : fn;
	}

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
		var binding:IrDebugBinding = {
			identity: "debug",
			name: "debug",
			value: debug,
			path: "test.hx",
			scopeStart: 0,
			scopeEnd: 1
		};
		var fn = new IrFunction("test", b.arguments, I32, b.blocks, Ordinary, [binding]);
		var before = IrFunctionStateCodec.encode(fn), result = removeDeadValues(fn);
		expect(before.compare(IrFunctionStateCodec.encode(fn)) == 0, "input was mutated");
		expect(result.blocks[0].instructions.length == 4,
			"dead chain removed, debug value, divisor, division and call retained");
		expect(result.debugBindings[0].value.id == debug.id, "debug value remains defined");
		expect(removeDeadValues(result) == result, "unchanged result retains identity");

		b = new IrBuilder();
		var condition = b.argument("condition", Bool),
			left = b.createBlock(),
			right = b.createBlock(),
			merge = b.createBlock();
		b.branch(condition, left, right);
		b.select(left);
		var a = b.constInt(40);
		b.jump(merge);
		b.select(right);
		var c = b.constInt(41);
		b.jump(merge);
		b.select(merge);
		var chosen = b.phi(I32, [{block: left.id, value: a}, {block: right.id, value: c}]);
		b.returnValue(b.add(chosen, b.constInt(2)));
		fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
		var program = new IrProgram("main");
		program.functions = [removeDeadValues(fn)];
		IrVerifier.verify(program);
		var interpreter = new IrInterpreter(program);
		expect(interpreter.run("main", [true]) == 42 && interpreter.run("main", [false]) == 43,
			"phi operands survive on both edges");
		b = new IrBuilder();
		b.valueInit("Point"); // An unused default value has no effect.
		var liveValue = b.valueInit("Point"), field = b.constInt(1);
		b.fieldSet(liveValue, "x", field);
		b.returnValue(field);
		fn = new IrFunction("values", b.arguments, I32, b.blocks, Ordinary);
		result = removeDeadValues(fn);
		var initializers = 0, stores = 0;
		for (instruction in result.blocks[0].instructions) switch instruction.value {
			case ValueInit(_): initializers++;
			case FieldSet(_, _, _): stores++;
			default:
		}
		expect(initializers == 1 && stores == 1, "dead defaults are removed and field writes keep their initializer");
		Sys.println("PASS: dead pure values preserve effects, debug bindings and live phi inputs");
	}
}
