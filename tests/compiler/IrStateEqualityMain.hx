import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.codec.IrFunctionStateEquality;

class IrStateEqualityMain {
	static function fn(instruction:IrInstruction, ?where:SourceProvenance):IrFunction {
		var v = new IrValue(0, "v", I32),
			w = new IrValue(1, "w", I32),
			b = new IrBlock(0);
		if (where == null)
			where = SourceProvenance.user(new compiler.Source.SourceFile("test.hx", "x").span(0, 1));
		b.instructions.push(new Located(instruction, where));
		b.terminator = new Located(Return(v), where);
		return new IrFunction("probe", [v, w], I32, [b], Ordinary, [
			{
				identity: "local",
				name: "v",
				value: v,
				path: "test.hx",
				scopeStart: 0,
				scopeEnd: 1
			}
		]);
	}

	static function compare(a:IrFunction, b:IrFunction):Void {
		var encoded = IrFunctionStateCodec.encode(a).compare(IrFunctionStateCodec.encode(b)) == 0;
		var same = IrFunctionStateEquality.same(a, b);
		if (same != encoded || same != IrFunctionStateEquality.same(b, a))
			throw "Structural and exact encoded IR state differ";
	}

	static function main():Void {
		var body = fn(ConstInt(new IrValue(0, "v", I32), 1));
		var adapter = new IrFunction(body.name, body.arguments, body.result, body.blocks, ClosureAdapter(Function([I32], I32), Function([Dyn], Dyn)), body.debugBindings, false, Reachable);
		var castFunction = new IrFunction(body.name, body.arguments, body.result, body.blocks, ClosureCast(Function([Dyn], Dyn)), body.debugBindings, false, Reachable);
		var otherAdapter = new IrFunction(body.name, body.arguments, body.result, body.blocks, ClosureAdapter(Function([I64], I32), Function([Dyn], Dyn)), body.debugBindings, false, Reachable);
		var retained = new IrFunction(body.name, body.arguments, body.result, body.blocks, adapter.kind, body.debugBindings, true, Keep);
		if (!IrFunctionStateEquality.same(retained, retained.withBlocks(retained.blocks)))
			throw "Replacing blocks must preserve function metadata";
		compare(adapter, IrFunctionStateCodec.decode(IrFunctionStateCodec.encode(adapter)));
		compare(adapter, castFunction);
		compare(adapter, otherAdapter);
		compare(body, adapter);
		for (kind in [GenericSpecialization, SourceLambda, Equality, ReflectiveEquality, Hash, KeyPath, IterationAdapter,
			GeneratedHelper, ScalarArguments, InlineEnumAccess, TypedInterface, ValueUnbox, GenericMethodReference,
			OptionalScalar(null), OptionalScalar("owner.method"), OptionalValueBoundary, NullableScalarArguments,
			ValueArrayElement, WasmClosureRestore]) {
			var functionWithKind = new IrFunction(body.name, body.arguments, body.result, body.blocks, kind, body.debugBindings);
			if (!IrFunctionStateEquality.same(functionWithKind, IrFunctionStateCodec.decode(IrFunctionStateCodec.encode(functionWithKind))))
				throw 'Function role failed to round-trip: $kind';
		}
		var v = new IrValue(0, "v", I32), w = new IrValue(1, "w", I32);
		var cases:Array<{original:IrInstruction, changed:Array<IrInstruction>}> = [
			{
				original: Phi(v, [{block: 0, value: v}]),
				changed: [
					Phi(new IrValue(2, "changed", Bytes), [{block: 0, value: v}]),
					Phi(v, [{block: 1, value: w}])
				]
			},
			{original: ConstVoid(v), changed: [ConstVoid(new IrValue(2, "changed", Bytes))]},
			{original: ConstInt(v, 0), changed: [ConstInt(new IrValue(2, "changed", Bytes), 0), ConstInt(v, 1)]},
			{original: ConstFloat(v, 1.5), changed: [ConstFloat(new IrValue(2, "changed", Bytes), 1.5), ConstFloat(v, -0.0)]},
			{original: ConstString(v, "name"), changed: [ConstString(new IrValue(2, "changed", Bytes), "name"), ConstString(v, "changed")]},
			{
				original: StaticDataAddress(v, [0, 255]),
				changed: [
					StaticDataAddress(new IrValue(2, "changed", Bytes), [0, 255]),
					StaticDataAddress(v, [0, 254])
				]
			},
			{
				original: PointerOffset(v, v, v),
				changed: [
					PointerOffset(new IrValue(2, "changed", Bytes), v, v),
					PointerOffset(v, new IrValue(2, "changed", Bytes), v),
					PointerOffset(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: MemoryLoad(v, v, 0, true),
				changed: [
					MemoryLoad(new IrValue(2, "changed", Bytes), v, 0, true),
					MemoryLoad(v, new IrValue(2, "changed", Bytes), 0, true),
					MemoryLoad(v, v, 1, true),
					MemoryLoad(v, v, 0, false)
				]
			},
			{
				original: MemoryStore(v, v, 0),
				changed: [
					MemoryStore(new IrValue(2, "changed", Bytes), v, 0),
					MemoryStore(v, new IrValue(2, "changed", Bytes), 0),
					MemoryStore(v, v, 1)
				]
			},
			{original: ConstBool(v, true), changed: [ConstBool(new IrValue(2, "changed", Bytes), true), ConstBool(v, false)]},
			{original: ConstNull(v), changed: [ConstNull(new IrValue(2, "changed", Bytes))]},
			{
				original: TypeValue(v, Function([Nullable(I64), Obj("Box")], Dyn)),
				changed: [
					TypeValue(new IrValue(2, "changed", Bytes), Function([Nullable(I64), Obj("Box")], Dyn)),
					TypeValue(v, I32)
				]
			},
			{
				original: ToDyn(v, v),
				changed: [
					ToDyn(new IrValue(2, "changed", Bytes), v),
					ToDyn(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: IntToFloat(v, v),
				changed: [
					IntToFloat(new IrValue(2, "changed", Bytes), v),
					IntToFloat(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: IntToInt64(v, v),
				changed: [
					IntToInt64(new IrValue(2, "changed", Bytes), v),
					IntToInt64(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: FloatToInt(v, v),
				changed: [
					FloatToInt(new IrValue(2, "changed", Bytes), v),
					FloatToInt(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: FloatToFloat(v, v),
				changed: [
					FloatToFloat(new IrValue(2, "changed", Bytes), v),
					FloatToFloat(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: SafeCast(v, v),
				changed: [
					SafeCast(new IrValue(2, "changed", Bytes), v),
					SafeCast(v, new IrValue(2, "changed", Bytes))
				]
			},
			{original: BeginTry(0, 0, true), changed: [BeginTry(1, 0, true), BeginTry(0, 1, true), BeginTry(0, 0, false)]},
			{original: EndTry(0, true), changed: [EndTry(1, true), EndTry(0, false)]},
			{original: Catch(v), changed: [Catch(new IrValue(2, "changed", Bytes))]},
			{original: GlobalGet(v, "name"), changed: [GlobalGet(new IrValue(2, "changed", Bytes), "name"), GlobalGet(v, "changed")]},
			{original: GlobalSet("name", v), changed: [GlobalSet("changed", v), GlobalSet("name", new IrValue(2, "changed", Bytes))]},
			{
				original: Add(v, v, v),
				changed: [
					Add(new IrValue(2, "changed", Bytes), v, v),
					Add(v, new IrValue(2, "changed", Bytes), v),
					Add(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Sub(v, v, v),
				changed: [
					Sub(new IrValue(2, "changed", Bytes), v, v),
					Sub(v, new IrValue(2, "changed", Bytes), v),
					Sub(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Mul(v, v, v),
				changed: [
					Mul(new IrValue(2, "changed", Bytes), v, v),
					Mul(v, new IrValue(2, "changed", Bytes), v),
					Mul(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Div(v, v, v),
				changed: [
					Div(new IrValue(2, "changed", Bytes), v, v),
					Div(v, new IrValue(2, "changed", Bytes), v),
					Div(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Mod(v, v, v),
				changed: [
					Mod(new IrValue(2, "changed", Bytes), v, v),
					Mod(v, new IrValue(2, "changed", Bytes), v),
					Mod(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: BitAnd(v, v, v),
				changed: [
					BitAnd(new IrValue(2, "changed", Bytes), v, v),
					BitAnd(v, new IrValue(2, "changed", Bytes), v),
					BitAnd(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: BitXor(v, v, v),
				changed: [
					BitXor(new IrValue(2, "changed", Bytes), v, v),
					BitXor(v, new IrValue(2, "changed", Bytes), v),
					BitXor(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: BitOr(v, v, v),
				changed: [
					BitOr(new IrValue(2, "changed", Bytes), v, v),
					BitOr(v, new IrValue(2, "changed", Bytes), v),
					BitOr(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: ShiftLeft(v, v, v),
				changed: [
					ShiftLeft(new IrValue(2, "changed", Bytes), v, v),
					ShiftLeft(v, new IrValue(2, "changed", Bytes), v),
					ShiftLeft(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: ShiftRight(v, v, v),
				changed: [
					ShiftRight(new IrValue(2, "changed", Bytes), v, v),
					ShiftRight(v, new IrValue(2, "changed", Bytes), v),
					ShiftRight(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: UnsignedShiftRight(v, v, v),
				changed: [
					UnsignedShiftRight(new IrValue(2, "changed", Bytes), v, v),
					UnsignedShiftRight(v, new IrValue(2, "changed", Bytes), v),
					UnsignedShiftRight(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Less(v, v, v),
				changed: [
					Less(new IrValue(2, "changed", Bytes), v, v),
					Less(v, new IrValue(2, "changed", Bytes), v),
					Less(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: LessEqual(v, v, v),
				changed: [
					LessEqual(new IrValue(2, "changed", Bytes), v, v),
					LessEqual(v, new IrValue(2, "changed", Bytes), v),
					LessEqual(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Equal(v, v, v),
				changed: [
					Equal(new IrValue(2, "changed", Bytes), v, v),
					Equal(v, new IrValue(2, "changed", Bytes), v),
					Equal(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Call(v, "name", [v, w]),
				changed: [
					Call(new IrValue(2, "changed", Bytes), "name", [v, w]),
					Call(v, "changed", [v, w]),
					Call(v, "name", [w, v])
				]
			},
			{
				original: CNativeCall(v, "name", [v, w]),
				changed: [
					CNativeCall(new IrValue(2, "changed", Bytes), "name", [v, w]),
					CNativeCall(v, "changed", [v, w]),
					CNativeCall(v, "name", [w, v])
				]
			},
			{
				original: StaticClosure(v, "name"),
				changed: [
					StaticClosure(new IrValue(2, "changed", Bytes), "name"),
					StaticClosure(v, "changed")
				]
			},
			{
				original: InstanceClosure(v, "name", v),
				changed: [
					InstanceClosure(new IrValue(2, "changed", Bytes), "name", v),
					InstanceClosure(v, "changed", v),
					InstanceClosure(v, "name", new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: CallClosure(v, v, [v, w]),
				changed: [
					CallClosure(new IrValue(2, "changed", Bytes), v, [v, w]),
					CallClosure(v, new IrValue(2, "changed", Bytes), [v, w]),
					CallClosure(v, v, [w, v])
				]
			},
			{
				original: ToVirtual(v, v),
				changed: [
					ToVirtual(new IrValue(2, "changed", Bytes), v),
					ToVirtual(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: Upcast(v, v),
				changed: [
					Upcast(new IrValue(2, "changed", Bytes), v),
					Upcast(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: MethodCall(v, v, "name", [v, w], true),
				changed: [
					MethodCall(new IrValue(2, "changed", Bytes), v, "name", [v, w], true),
					MethodCall(v, new IrValue(2, "changed", Bytes), "name", [v, w], true),
					MethodCall(v, v, "changed", [v, w], true),
					MethodCall(v, v, "name", [w, v], true),
					MethodCall(v, v, "name", [v, w], false)
				]
			},
			{original: NewObject(v, "name"), changed: [NewObject(new IrValue(2, "changed", Bytes), "name"), NewObject(v, "changed")]},
			{
				original: FieldGet(v, v, "name"),
				changed: [
					FieldGet(new IrValue(2, "changed", Bytes), v, "name"),
					FieldGet(v, new IrValue(2, "changed", Bytes), "name"),
					FieldGet(v, v, "changed")
				]
			},
			{
				original: FieldSet(v, "name", v),
				changed: [
					FieldSet(new IrValue(2, "changed", Bytes), "name", v),
					FieldSet(v, "changed", v),
					FieldSet(v, "name", new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: ArrayGet(v, v, v),
				changed: [
					ArrayGet(new IrValue(2, "changed", Bytes), v, v),
					ArrayGet(v, new IrValue(2, "changed", Bytes), v),
					ArrayGet(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: ArraySet(v, v, v),
				changed: [
					ArraySet(new IrValue(2, "changed", Bytes), v, v),
					ArraySet(v, new IrValue(2, "changed", Bytes), v),
					ArraySet(v, v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: ArraySize(v, v),
				changed: [
					ArraySize(new IrValue(2, "changed", Bytes), v),
					ArraySize(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: IteratorNew(v, v),
				changed: [
					IteratorNew(new IrValue(2, "changed", Bytes), v),
					IteratorNew(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: IteratorHasNext(v, v),
				changed: [
					IteratorHasNext(new IrValue(2, "changed", Bytes), v),
					IteratorHasNext(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: IteratorNext(v, v),
				changed: [
					IteratorNext(new IrValue(2, "changed", Bytes), v),
					IteratorNext(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: MakeEnum(v, "name", 0, [v, w]),
				changed: [
					MakeEnum(new IrValue(2, "changed", Bytes), "name", 0, [v, w]),
					MakeEnum(v, "changed", 0, [v, w]),
					MakeEnum(v, "name", 1, [v, w]),
					MakeEnum(v, "name", 0, [w, v])
				]
			},
			{
				original: EnumIndex(v, v),
				changed: [
					EnumIndex(new IrValue(2, "changed", Bytes), v),
					EnumIndex(v, new IrValue(2, "changed", Bytes))
				]
			},
			{
				original: EnumField(v, v, 0, 0),
				changed: [
					EnumField(new IrValue(2, "changed", Bytes), v, 0, 0),
					EnumField(v, new IrValue(2, "changed", Bytes), 0, 0),
					EnumField(v, v, 1, 0),
					EnumField(v, v, 0, 1)
				]
			}
		];
		var checks = 0;
		for (entry in cases) {
			compare(fn(entry.original), fn(entry.original));
			checks++;
			for (changed in entry.changed) {
				compare(fn(entry.original), fn(changed));
				checks++;
			}
		}
		for (a in [
			0.0,
			-0.0,
			1.5,
			Math.POSITIVE_INFINITY,
			Math.NEGATIVE_INFINITY,
			Math.NaN,
			haxe.io.FPHelper.i64ToDouble(1, 0x7ff80000),
			haxe.io.FPHelper.i64ToDouble(2, 0x7ff80000)
		])
			for (b in [0.0, -0.0, 1.5, Math.NaN, haxe.io.FPHelper.i64ToDouble(2, 0x7ff80000)]) {
				compare(fn(ConstFloat(v, a)), fn(ConstFloat(v, b)));
				checks++;
			}
		for (text in ["x", " x", "x // comment"]) {
			var span = new compiler.Source.SourceFile("test.hx", text).span(text == " x" ? 1 : 0, text == " x" ? 2 : 1);
			compare(fn(ConstInt(v, 42)), fn(ConstInt(v, 42), SourceProvenance.user(span)));
			checks++;
		}
		var original = fn(ConstInt(v, 42));
		var changedBindings = [
			{
				identity: "other",
				name: "other",
				value: w,
				path: "other.hx",
				scopeStart: 1,
				scopeEnd: 2
			}
		];
		for (changed in [
			new IrFunction("renamed", original.arguments, original.result, original.blocks, Ordinary, original.debugBindings),
			new IrFunction(original.name, [w, v], original.result, original.blocks, Ordinary, original.debugBindings),
			new IrFunction(original.name, original.arguments, I64, original.blocks, Ordinary, original.debugBindings),
			new IrFunction(original.name, original.arguments, original.result, original.blocks, Ordinary, changedBindings),
			new IrFunction(original.name, original.arguments, original.result, original.blocks, Ordinary, original.debugBindings, true),
			new IrFunction(original.name, original.arguments, original.result, original.blocks, Ordinary, original.debugBindings, false,
				compiler.ir.IrFunction.IrRetention.Keep),
			fn(ConstInt(v, 42), SourceProvenance.generated("first")),
			fn(ConstInt(v, 42), SourceProvenance.generated("second"))
		]) {
			compare(original, changed);
			checks++;
		}
		Sys.println("PASS: " + checks + " exact-state checks across every IR instruction and IEEE float provenance edge cases");
	}
}
