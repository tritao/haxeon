import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;

/**
 * Functions in a call cycle are not inlined into each other, so their inlined form depends only on their own source and on callees
 * outside the cycle. They get a memo, and a second compile of the same program reuses them.
 */
class InlinerCycleMain {
	static function step(name:String, other:String):IrFunction {
		var b = new IrBuilder(), value = b.argument("value", I32);
		value = b.add(value, b.constInt(1));
		value = b.call(other, [value], I32);
		b.returnValue(value);
		return new IrFunction(name, b.arguments, I32, b.blocks, Ordinary);
	}

	static function leaf():IrFunction {
		var b = new IrBuilder(), value = b.argument("value", I32);
		value = b.add(value, b.constInt(1));
		b.returnValue(value);
		return new IrFunction("leaf", b.arguments, I32, b.blocks, Ordinary);
	}

	static function program():IrProgram {
		var p = new IrProgram("outer");
		p.functions.push(leaf());
		p.functions.push(step("ping", "pong"));
		p.functions.push(step("pong", "ping"));
		var b = new IrBuilder(), value = b.argument("value", I32);
		value = b.call("leaf", [value], I32);
		value = b.call("pong", [value], I32);
		b.returnValue(value);
		p.functions.push(new IrFunction("outer", b.arguments, I32, b.blocks, Ordinary));
		return p;
	}

	static function callees(program:IrProgram, name:String):Array<String> {
		var result = [];
		for (fn in program.functions)
			if (fn.name == name)
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, callee, _):
								result.push(callee.name);
							default:
						}
		return result;
	}

	static function named(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'missing $name';
	}

	static function main():Void {
		var session = new InlinerSession(), first = program();
		session.run(first);
		expect(callees(first, "ping").indexOf("pong") >= 0, "ping keeps its call to pong, which is in its cycle");
		expect(callees(first, "pong").indexOf("ping") >= 0, "pong keeps its call to ping");
		expect(callees(first, "outer").indexOf("leaf") < 0, "a function outside the cycle still inlines leaf");
		for (name in ["ping", "pong", "outer"])
			expect(session.computedIn(name) != 0, '$name has a memo');
		var memos = [for (name in ["ping", "pong", "outer"]) session.computedIn(name)];
		var second = program();
		var changed = session.run(second);
		expect(changed.length == 0, "the same program changes nothing");
		// A run that checks its reuse recomputes the memos and compares them; this one does not, so it keeps the objects.
		for (i => name in ["ping", "pong", "outer"])
			expect(session.computedIn(name) == memos[i], '$name keeps its memo');
		Sys.println("PASS: call cycles are memoized and not inlined into each other");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
