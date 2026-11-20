import compiler.ir.Ir;
import compiler.ir.IrBody;
import compiler.ir.IrBodyBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrSymbol;
import compiler.ir.IrTypeIds;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateEquality;

/** Every instruction and terminator kind round-trips through an `IrBody`, and the body's accessors read what was encoded. */
class IrBodyMain {
	static var nextId = 0;

	static function value(name:String, type:IrType):IrValue
		return new IrValue(nextId++, name, type);

	static function main():Void {
		var file = new compiler.core.Source.SourceFile("test.hx", "first\nsecond");
		var user = SourceProvenance.user(file.span(0, 5)),
			other = SourceProvenance.user(file.span(6, 12)),
			generated = SourceProvenance.generated("test");
		var a = value("a", I32),
			b = value("b", I32),
			f = value("f", F64),
			o = value("o", Obj("Point")),
			d = value("d", Dyn),
			p = value("p", RawPtr),
			arr = value("arr", Array(I32)),
			e = value("e", Enum("Shape")),
			closure = value("closure", Function([I32], I32));
		var instructions:Array<IrInstruction> = [
			ConstVoid(value("void", Void)),
			ConstInt(value("int", I32), -7),
			ConstFloat(value("float", F64), 1.5),
			ConstFloat(value("negativeZero", F64), -0.0),
			ConstFloat(value("nan", F64), Math.NaN),
			ConstString(value("string", Bytes), "text"),
			StaticDataAddress(value("data", RawPtr), [0, 255, 7]),
			StaticDataAddress(value("empty", RawPtr), []),
			PointerOffset(value("offset", RawPtr), p, a),
			MemoryLoad(value("load", I32), p, 4, true),
			MemoryLoad(value("unsigned", I32), p, 2, false),
			MemoryStore(p, a, 8),
			ConstBool(value("yes", Bool), true),
			ConstBool(value("no", Bool), false),
			ConstNull(value("null", Dyn)),
			TypeValue(value("type", TypeRef), Nullable(Array(Obj("Point")))),
			ToDyn(value("toDyn", Dyn), a),
			IntToFloat(value("toFloat", F64), a),
			IntToInt64(value("toLong", I64), a),
			FloatToInt(value("toInt", I32), f),
			FloatToFloat(value("toSingle", F32), f),
			SafeCast(value("cast", Obj("Point")), d),
			BeginTry(2, 3, true),
			EndTry(2, false),
			Catch(value("caught", Dyn)),
			GlobalGet(value("global", I32), "Main.counter"),
			GlobalSet("Main.counter", a),
			Add(value("add", I32), a, b),
			Sub(value("sub", I32), a, b),
			Mul(value("mul", I32), a, b),
			Div(value("div", F64), f, f),
			Mod(value("mod", I32), a, b),
			BitAnd(value("and", I32), a, b),
			BitXor(value("xor", I32), a, b),
			BitOr(value("or", I32), a, b),
			ShiftLeft(value("shl", I32), a, b),
			ShiftRight(value("shr", I32), a, b),
			UnsignedShiftRight(value("ushr", I32), a, b),
			Less(value("less", Bool), a, b),
			LessEqual(value("lessEqual", Bool), a, b),
			Equal(value("equal", Bool), a, b),
			Call(value("call", I32), IrSymbol.of("Main.f"), [a, b]),
			Call(value("noArguments", Void), IrSymbol.of("Main.g"), []),
			CNativeCall(value("native", I32), "c_add", [a, b]),
			StaticClosure(value("static", Function([I32], I32)), IrSymbol.of("Main.f")),
			InstanceClosure(value("bound", Function([], I32)), IrSymbol.of("Point.get"), o),
			CallClosure(value("called", I32), closure, [a]),
			ToVirtual(value("virtual", Virtual("V")), o),
			Upcast(value("upcast", Obj("Base")), o),
			ClassId(value("classId", I32), o),
			MethodCall(value("method", I32), o, "get", [a], false),
			MethodCall(value("terminal", I32), o, "take", [], true),
			NewObject(value("object", Obj("Point")), "Point"),
			ValueInit(value("init", Obj("Point"))),
			FieldGet(value("field", I32), o, "x"),
			FieldSet(o, "x", a),
			ArrayGet(value("element", I32), arr, a),
			ArraySet(arr, a, b),
			ArraySize(value("size", I32), arr),
			IteratorNew(value("iterator", Iterator(I32)), arr),
			IteratorHasNext(value("hasNext", Bool), value("it", Iterator(I32))),
			IteratorNext(value("next", I32), value("it2", Iterator(I32))),
			MakeEnum(value("circle", Enum("Shape")), "Shape", 1, [f]),
			MakeEnum(value("none", Enum("Shape")), "Shape", 0, []),
			EnumIndex(value("index", I32), e),
			EnumField(value("radius", F64), e, 1, 0),
			Intrinsic(value("box", Dyn), EnumDynamicBox(Enum("Shape")), [e]),
			Intrinsic(value("view", Enum("Shape")), EnumDynamicView(Enum("Shape")), [d]),
			Intrinsic(value("tagBox", Dyn), EnumTagBox(EnumTag("Color")), [a]),
			Intrinsic(value("tagUnbox", EnumTag("Color")), EnumTagUnbox(EnumTag("Color")), [d]),
			Intrinsic(value("inlineBox", Enum("Shape")), InlineEnumBox(Enum("Shape")), [o]),
			Intrinsic(value("inlineUnbox", Obj("ShapeValue")), InlineEnumUnbox(Enum("Shape")), [e])
		];
		var phi = value("phi", I32);
		var entry = new IrBlock(0);
		entry.instructions.push(new Located(Phi(phi, [{block: 1, value: a}, {block: 2, value: b}]), user));
		for (index in 0...instructions.length)
			entry.instructions.push(new Located(instructions[index],
				index % 3 == 0 ? user : index % 3 == 1 ? other : generated));
		entry.terminator = new Located(Branch(value("condition", Bool), 1, 2), user);
		var terminators:Array<IrTerminator> = [
			Unreachable,
			Return(a),
			Throw(d),
			Rethrow(d),
			Jump(0),
			Switch(a, [3, 4, 5], 6)
		];
		var blocks = [entry];
		for (index in 0...terminators.length) {
			var block = new IrBlock(10 + index);
			block.terminator = new Located(terminators[index], generated);
			blocks.push(block);
		}
		var open = new IrBlock(20);
		open.instructions.push(new Located(ConstInt(value("pending", I32), 1), user));
		blocks.push(open);
		blocks.push(new IrBlock(21));
		var fn = new IrFunction("Main.probe", [a, b, f, o, d, p, arr, e, closure], I32, blocks,
			ClosureAdapter(Function([I32], I32), Function([Dyn], Dyn)), [
				{
					identity: "local:a",
					name: "a",
					value: a,
					path: "test.hx",
					scopeStart: 0,
					scopeEnd: 5
				},
				{
					identity: "local:phi",
					name: "phi",
					value: phi,
					path: "test.hx",
					scopeStart: 6,
					scopeEnd: 12
				}
			], true, Keep);
		var types = new IrTypeIds();
		check(fn, types);
		var opcodes:Map<Int, Bool> = [];
		var body = IrBodyBuilder.encode(fn, types);
		for (row in 0...body.rowCount())
			opcodes.set(body.opcode(row), true);
		for (opcode in 0...compiler.ir.IrOpcode.COUNT)
			if (!opcodes.exists(opcode))
				throw 'The test covers no row with opcode $opcode';
		expect(body.blockCount() == blocks.length, "block count");
		expect(body.blockId(1) == 10 && body.terminatorRow(blocks.length - 2) == -1
			&& body.terminatorRow(blocks.length - 1) == -1, "blocks without terminators");
		var branch = body.terminatorRow(0);
		expect(body.opcode(branch) == compiler.ir.IrOpcode.Branch && body.successorCount(branch) == 2
			&& body.successor(branch, 0) == 1
			&& body.successor(branch, 1) == 2, "branch successors");
		var switchRow = body.terminatorRow(6);
		expect(body.opcode(switchRow) == compiler.ir.IrOpcode.Switch && body.successorCount(switchRow) == 4
			&& body.successor(switchRow, 2) == 5 && body.successor(switchRow, 3) == 6, "switch successors");
		expect(body.definingRow(phi.id) == 0 && body.definingRow(a.id) == -1, "defining rows");
		expect(body.valueName(phi.id) == "phi" && body.valueTypeId(a.id) == body.valueTypeId(b.id),
			"value columns");
		expect(body.operandCount(0) == 2 && body.operand(0, 1) == b.id && body.auxInt(0, 1) == 2, "phi inputs");
		var methodRow = -1;
		for (row in 0...body.rowCount())
			if (body.opcode(row) == compiler.ir.IrOpcode.MethodCall && methodRow < 0)
				methodRow = row;
		expect(body.symbol(methodRow).name == "get" && body.operand(methodRow, 0) == o.id, "method call");
		// A function with no blocks, no arguments and a second value table round-trips too.
		nextId = 0;
		check(new IrFunction("Main.empty", [], Void, [], Ordinary), types);
		// The check catches a value whose id carries two types: one column cannot hold both.
		var clash = new IrBlock(0);
		clash.instructions.push(new Located(ConstInt(new IrValue(0, "x", I32), 1), user));
		clash.terminator = new Located(Return(new IrValue(0, "x", I64)), user);
		if (IrBody.roundTripDifference(new IrFunction("Main.clash", [], I32, [clash], Ordinary), types) == null)
			throw "A value id with two types must not round-trip";
		// The pipeline's round trip is its own option, off by default, and implies verification.
		var options = compiler.CompileOptions.fromArguments(["--no-verify-ir", "--check-ir-body"]);
		expect(!new compiler.CompileOptions().checkIrBody, "the body check is off by default");
		expect(options.checkIrBody && options.verifyIr && options.arguments().join(" ") == "--check-ir-body",
			"the body check as a flag");
	}

	static function check(fn:IrFunction, types:IrTypeIds):Void {
		var difference = IrBody.roundTripDifference(fn, types);
		if (difference != null)
			throw 'Round trip of ${fn.name} failed: $difference';
		var decoded = IrBodyBuilder.encode(fn, types).toFunction();
		if (!IrFunctionStateEquality.same(decoded, fn))
			throw 'Round trip of ${fn.name} is not symmetric';
	}

	static function expect(condition:Bool, what:String):Void
		if (!condition)
			throw 'IrBody: $what';
}
