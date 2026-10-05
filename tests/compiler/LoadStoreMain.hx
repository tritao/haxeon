import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInliner;
import compiler.ir.IrObjectTable;
import compiler.ir.IrInliner.IrInlineCache;
import compiler.ir.IrLoadStoreForwarding;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;

class LoadStoreMain {
	static function located(i:IrInstruction):Located<IrInstruction>
		return new Located(i, SourceProvenance.generated("loadstore-test"));

	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function loads(fn:IrFunction):Int {
		var n = 0;
		for (b in fn.blocks)
			for (loc in b.instructions)
				switch loc.value {
					case FieldGet(_, _, _), ArrayGet(_, _, _):
						n++;
					default:
				}
		return n;
	}

	static function finish(b:IrBuilder, out:IrValue):IrFunction {
		b.returnValue(out);
		return new IrFunction("test", b.arguments, out.type, b.blocks);
	}

	static function fieldCase(name:String, gap:(IrBuilder, IrValue, IrValue) -> Void, expected:Int):Void {
		var b = new IrBuilder(),
			o = b.argument("o", Obj("Box")),
			other = b.argument("alias", Obj("Box"));
		var first = b.fieldGet(o, "n", I32);
		gap(b, o, other);
		var second = b.fieldGet(o, "n", I32),
			fn = finish(b, b.add(first, second));
		var bytes = IrFunctionStateCodec.encode(fn);
		var result = IrLoadStoreForwarding.run(fn);
		expect(loads(result) == expected, name);
		expect(bytes.compare(IrFunctionStateCodec.encode(fn)) == 0, "input mutated: " + name);
		expect(IrLoadStoreForwarding.run(result) == result, "idempotent identity: " + name);
	}

	static function arrayCase(name:String, unknown:Bool, alias:Bool, same:Bool, expected:Int):Void {
		var b = new IrBuilder(),
			a = b.argument("a", Array(I32)),
			other = b.argument("alias", Array(I32));
		var i = unknown ? b.argument("i", I32) : b.constInt(0);
		var j = same ? (unknown ? i : b.constInt(0)) : (unknown ? b.argument("j", I32) : b.constInt(1));
		var first = new IrValue(100, "first", I32),
			last = new IrValue(101, "last", I32);
		b.blocks[0].instructions.push(located(ArrayGet(first, a, i)));
		b.blocks[0].instructions.push(located(ArraySet(alias ? other : a, j, b.constInt(8))));
		b.blocks[0].instructions.push(located(ArrayGet(last, a, i)));
		expect(loads(IrLoadStoreForwarding.run(finish(b, b.add(first, last)))) == expected, name);
	}

	static function main():Void {
		var b = new IrBuilder(),
			o = b.argument("o", Obj("Box")),
			stored = b.constInt(42);
		b.fieldSet(o, "n", stored);
		var reload = b.fieldGet(o, "n", I32), fn = finish(b, reload);
		var binding:IrDebugBinding = {
			identity: "n",
			name: "n",
			value: reload,
			path: "test.hx",
			scopeStart: 0,
			scopeEnd: 10
		};
		fn = new IrFunction(fn.name, fn.arguments, fn.result, fn.blocks, [binding]);
		var result = IrLoadStoreForwarding.run(fn);
		expect(loads(result) == 0, "store then load");
		expect(result.debugBindings[0].value == stored, "debug binding substitution");
		switch result.blocks[0].terminator.value {
			case Return(v):
				expect(v == stored, "return substitution");
			default:
				throw "return";
		}
		expect(result.blocks[0].instructions[1].provenance == fn.blocks[0].instructions[1].provenance, "surviving provenance");
		fieldCase("repeat", function(b, o, a) {}, 1);
		fieldCase("alias", function(b, o, a) b.fieldSet(a, "n", b.constInt(8)), 2);
		fieldCase("other field", function(b, o, a) b.fieldSet(a, "m", b.constInt(8)), 1);
		fieldCase("call", function(b, o, a) b.call("mutate", [o], Void), 2);
		fieldCase("native call", function(b, o, a) b.cNativeCall("mutate", [o], Void), 2);
		fieldCase("closure", function(b, o, a) b.callClosure(b.argument("closure", Function([], Void)), [], Void), 2);
		fieldCase("method", function(b, o, a) b.blocks[0].instructions.push(located(MethodCall(new IrValue(100, "call", Void), o, "mutate", []))), 2);
		fieldCase("try", function(b, o, a) b.blocks[0].instructions.push(located(BeginTry(1, 2))), 2);
		fieldCase("end try", function(b, o, a) b.blocks[0].instructions.push(located(EndTry(1))), 2);
		fieldCase("catch", function(b, o, a) b.blocks[0].instructions.push(located(Catch(new IrValue(100, "error", Dyn)))), 2);
		fieldCase("raw store", function(b, o, a) b.blocks[0].instructions.push(located(MemoryStore(b.argument("ptr", RawPtr), b.constInt(8), 4))), 2);
		fieldCase("fresh allocation", function(b, o, a) b.newObject("Box"), 1);
		arrayCase("same constant", false, false, true, 1);
		arrayCase("distinct constants", false, false, false, 1);
		arrayCase("same SSA index", true, false, true, 1);
		arrayCase("unknown indices", true, false, false, 2);
		arrayCase("array alias constants", false, true, false, 2);
		arrayCase("array alias indices", true, true, false, 2);
		b = new IrBuilder();
		o = b.argument("o", Obj("Box"));
		var nullable = b.argument("nullable", Nullable(I32));
		b.fieldSet(o, "dyn", nullable);
		expect(loads(IrLoadStoreForwarding.run(finish(b, b.fieldGet(o, "dyn", Dyn)))) == 1, "exact types only");
		var objects:Map<String, IrObject> = [];
		objects.set("Value", {
			name: "Value",
			isValue: true,
			base: null,
			interfaces: [],
			fields: [{name: "n", type: I32}],
			methods: []
		});
		b = new IrBuilder();
		o = b.argument("o", Obj("Box"));
		var value = b.argument("v", Obj("Value"));
		b.fieldSet(o, "v", value);
		var v1 = b.fieldGet(o, "v", Obj("Value")),
			v2 = b.fieldGet(o, "v", Obj("Value"));
		expect(loads(IrLoadStoreForwarding.run(finish(b, v2), IrObjectTable.of(objects))) == 2, "inline value fields must not be forwarded");
		// Replacing an inline value also changes primitive fields reached through interior pointers.
		b = new IrBuilder();
		o = b.argument("holder", Obj("Box"));
		var interior = b.argument("interior", Obj("Value"));
		value = b.argument("replacement", Obj("Value"));
		b.fieldGet(interior, "n", I32);
		b.fieldSet(o, "v", value);
		expect(loads(IrLoadStoreForwarding.run(finish(b, b.fieldGet(interior, "n", I32)), IrObjectTable.of(objects))) == 2,
			"inline copies kill interior facts");
		// Facts stop at blocks, but eliminated values are substituted in successor phis.
		b = new IrBuilder();
		o = b.argument("o", Obj("Box"));
		stored = b.constInt(42);
		b.fieldSet(o, "n", stored);
		reload = b.fieldGet(o, "n", I32);
		var next = b.createBlock();
		b.jump(next);
		b.select(next);
		var phi = b.phi(I32, [{block: 0, value: reload}]);
		var later = b.fieldGet(o, "n", I32);
		result = IrLoadStoreForwarding.run(finish(b, b.add(phi, later)));
		expect(loads(result) == 1, "no cross-block facts");
		switch result.blocks[1].instructions[0].value {
			case Phi(_, inputs):
				expect(inputs[0].value == stored, "phi substitution");
			default:
				throw "phi";
		}
		// Disabled inlining still publishes forwarding, and changing its switch invalidates memoized output.
		var oldInline = IrInliner.enabled,
			oldForward = IrLoadStoreForwarding.enabled;
		IrInliner.enabled = false;
		IrLoadStoreForwarding.enabled = true;
		var program = new IrProgram("test"), cache = new IrInlineCache();
		program.functions = [fn];
		IrInliner.run(program, cache);
		expect(loads(program.functions[0]) == 0, "forward with inliner off");
		program.functions = [fn];
		expect(IrInliner.run(program, cache).length == 0, "memo unchanged");
		IrLoadStoreForwarding.enabled = false;
		program.functions = [fn];
		expect(IrInliner.run(program, cache).indexOf("test") >= 0, "switch changes published bytes");
		expect(program.functions[0] == fn, "disabled pass identity");
		IrInliner.enabled = oldInline;
		IrLoadStoreForwarding.enabled = oldForward;
		Sys.println("PASS: load/store forwarding");
	}
}
