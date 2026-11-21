import compiler.ir.Ir;
import compiler.ir.IrBody;
import compiler.ir.IrBodyBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrSymbol;
import compiler.ir.IrTypeIds;
import compiler.ir.IrValueId;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrFunctionStateEquality;

/**
 * Every instruction and terminator kind round-trips through an `IrBody`, and the body's accessors read what was encoded. The
 * passes over bodies give what their object versions give.
 */
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
		for (row in 0...body.rowLimit())
			opcodes.set(body.opcode(row), true);
		for (opcode in 0...compiler.ir.IrOpcode.COUNT)
			if (!opcodes.exists(opcode))
				throw 'The test covers no row with opcode $opcode';
		expect(body.blockCount() == blocks.length, "block count");
		expect(body.blockId(1) == 10 && body.terminatorRow(blocks.length - 2) == -1
			&& body.firstRow(blocks.length - 1) == -1
			&& body.terminatorRow(blocks.length - 1) == -1, "blocks without terminators");
		var branch = body.terminatorRow(0);
		expect(body.opcode(branch) == compiler.ir.IrOpcode.Branch && body.successorCount(branch) == 2
			&& body.successor(branch, 0) == 1
			&& body.successor(branch, 1) == 2, "branch successors");
		var switchRow = body.terminatorRow(6);
		expect(body.opcode(switchRow) == compiler.ir.IrOpcode.Switch && body.successorCount(switchRow) == 4
			&& body.successor(switchRow, 2) == 5 && body.successor(switchRow, 3) == 6, "switch successors");
		expect(body.definingRow(IrValueId.of(phi.id)) == 0 && body.definingRow(IrValueId.of(a.id)) == -1,
			"defining rows");
		expect(body.valueName(IrValueId.of(phi.id)) == "phi"
			&& body.valueTypeId(IrValueId.of(a.id)) == body.valueTypeId(IrValueId.of(b.id)), "value columns");
		expect(body.operandCount(0) == 2 && body.operand(0, 1) == IrValueId.of(b.id) && body.auxInt(0, 1) == 2,
			"phi inputs");
		var methodRow = -1, row = body.firstRow(0);
		while (row >= 0 && methodRow < 0) {
			if (body.opcode(row) == compiler.ir.IrOpcode.MethodCall)
				methodRow = row;
			row = body.nextRow(row);
		}
		expect(body.symbol(methodRow).name == "get" && body.operand(methodRow, 0) == IrValueId.of(o.id), "method call");
		edits(body);
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
		bodyPasses();
		expect(options.checkIrBody && options.verifyIr && options.arguments().join(" ") == "--check-ir-body",
			"the body check as a flag");
	}

	static function block(id:Int, instructions:Array<IrInstruction>, terminator:Null<IrTerminator>):IrBlock {
		var where = SourceProvenance.generated("body-pass-test"), result = new IrBlock(id);
		for (instruction in instructions)
			result.instructions.push(new Located(instruction, where));
		if (terminator != null)
			result.terminator = new Located(terminator, where);
		return result;
	}

	/**
	 * Runs a pass on `fn` and on its body; both must change it, and the same way. The edited body keeps a sound layout, and
	 * compacts to an equal function.
	 */
	static function samePass(what:String, fn:IrFunction, objectPass:IrFunction->IrFunction,
			bodyPass:(IrBody, compiler.ir.IrPassScratch) -> Bool):Void {
		var types = new IrTypeIds(),
			scratch = new compiler.ir.IrPassScratch(),
			body = IrBodyBuilder.encode(fn, types),
			expected = objectPass(fn);
		if (expected == fn || !bodyPass(body, scratch))
			throw 'IrBody: the $what test function must change';
		var layout = body.layoutDifference();
		if (layout != null)
			throw 'IrBody: $what left a broken layout: $layout';
		var difference = IrFunctionStateEquality.difference(expected, body.toFunction());
		if (difference != null)
			throw 'IrBody: $what on a body differs from its object version: $difference';
		var frozen = body.freeze(scratch.bodyBuilder);
		if (frozen == body || !frozen.frozen || frozen.layoutDifference() != null
			|| IrFunctionStateEquality.difference(expected, frozen.toFunction()) != null)
			throw 'IrBody: $what: the frozen body must be a compacted copy equal to the edited one';
	}

	/**
	 * Rows made or copied here and linked before, after or into new blocks; a block's tail moved to another. The layout stays
	 * sound and the decoded function has the rows where they were linked.
	 */
	static function construction(body:IrBody):Void {
		var where = SourceProvenance.generated("construction-test"), int = body.typeId(I32);
		var made = body.newValue("made", int);
		body.beginRow();
		var row = body.endRow(compiler.ir.IrOpcode.ConstInt, made, 42, where);
		var first = body.firstRow(0);
		body.linkBefore(0, body.nextRow(first), row);
		expect(body.nextRow(first) == row && body.definingRow(made) == row && body.layoutDifference() == null,
			"linking a made row");
		var sum = body.newValue("sum", int);
		body.beginRow();
		body.pushOperand(made);
		body.pushOperand(made);
		var add = body.endRow(compiler.ir.IrOpcode.Add, sum, 0, where);
		body.linkAfter(0, row, add);
		var values = [for (_ in 0...body.valueLimit()) -1];
		var copiedValue = body.newValue("copied", int);
		values[sum] = copiedValue;
		var copy = body.copyRow(body, add, values);
		var count = body.blockCount();
		body.addBlock(count, 99);
		body.linkAfter(count, -1, copy);
		expect(body.operand(copy, 0) == made && body.output(copy) == copiedValue && body.firstRow(count) == copy
			&& body.layoutDifference() == null, "copying a row into a new block");
		var moved = body.nextRow(add);
		body.moveTail(0, moved, count);
		expect(body.nextRow(add) == -1 && body.lastRow(0) == add && body.nextRow(copy) == moved
			&& body.layoutDifference() == null, "moving a block's tail");
		var decoded = body.toFunction();
		expect(decoded.blocks[0].instructions.length == 3 && decoded.blocks[0].terminator == null
			&& decoded.blocks[count].id == 99
			&& decoded.blocks[count].terminator != null, "the decoded rows are where they were linked");
	}

	/** Edits keep the layout sound and say what changed; a frozen body refuses them; a thawed copy takes them. */
	static function edits(source:IrBody):Void {
		var body = source.thaw();
		var last = body.lastRow(0), before = body.previousRow(last);
		var removedOutput = body.output(before);
		body.removeRow(0, before);
		expect(body.previousRow(last) != before && body.definingRow(removedOutput) == -1
			&& body.layoutDifference() == null, "removing a row");
		body.addPhiInput(body.firstRow(0), 7, body.argument(0));
		expect(body.operandCount(body.firstRow(0)) == 3 && body.auxInt(body.firstRow(0), 2) == 7
			&& body.layoutDifference() == null, "adding a phi input moves its runs");
		body.removePhiInput(body.firstRow(0), 0);
		expect(body.operandCount(body.firstRow(0)) == 2 && body.auxInt(body.firstRow(0), 0) == 2,
			"removing a phi input");
		var blocks = body.blockCount();
		body.removeBlock(blocks - 1);
		expect(body.blockCount() == blocks - 1 && body.layoutDifference() == null, "removing a block");
		var frozen = body.freeze();
		expect(frozen != body && frozen.frozen && frozen.layoutDifference() == null
			&& IrFunctionStateEquality.difference(body.toFunction(), frozen.toFunction()) == null, "freezing compacts");
		var refused = false;
		try
			frozen.setAux(frozen.firstRow(0), 0)
		catch (error:compiler.core.InternalError)
			refused = true;
		expect(refused, "a frozen body refuses edits");
		construction(source.thaw());
		var unedited = source.thaw();
		expect(unedited.freeze() == unedited, "freezing an unedited body keeps it");
	}

	static function bodyPasses():Void {
		nextId = 0;
		var condition = value("condition", Bool),
			x = value("x", I32),
			dead = value("dead", I32),
			deadSum = value("deadSum", I32),
			kept = value("kept", I32);
		samePass("dead pure values", new IrFunction("Main.dead", [condition, x], I32, [
			block(0, [ConstInt(dead, 1), Add(deadSum, dead, x), Add(kept, x, x)], Return(kept))
		], Ordinary), fn -> compiler.ir.IrDeadPureValues.run(fn),
			(body, scratch) -> compiler.ir.IrDeadPureValues.runBody(body, scratch));
		samePass("jump threading", new IrFunction("Main.bridges", [condition, x], I32, [
			block(0, [], Branch(condition, 1, 2)),
			block(1, [], Jump(3)),
			block(2, [], Jump(4)),
			block(4, [], Jump(3)),
			block(3, [], Return(x))
		], Ordinary), fn -> compiler.ir.IrJumpThreading.run(fn),
			(body, scratch) -> compiler.ir.IrJumpThreading.runBody(body, scratch));
		var yes = value("yes", Bool),
			no = value("no", Bool),
			joined = value("joined", Bool),
			one = value("one", I32),
			two = value("two", I32);
		samePass("constant branches", new IrFunction("Main.constants", [condition, x], I32, [
			block(0, [], Branch(condition, 1, 2)),
			block(1, [ConstBool(yes, true)], Jump(3)),
			block(2, [ConstBool(no, false)], Jump(3)),
			block(3, [Phi(joined, [{block: 1, value: yes}, {block: 2, value: no}])], Branch(joined, 4, 5)),
			block(4, [ConstInt(one, 1)], Return(one)),
			block(5, [ConstInt(two, 2)], Return(two))
		], Ordinary), fn -> compiler.ir.IrJumpThreading.threadConstantBranches(fn),
			(body, scratch) -> compiler.ir.IrJumpThreading.threadConstantBranchesBody(body, scratch));
		var reference = value("reference", RawPtr),
			stored = value("stored", Void),
			loaded = value("loaded", I32),
			address = IrSymbol.of(compiler.ir.IrHlScalarRef.ADDRESS),
			store = IrSymbol.of(compiler.ir.IrHlScalarRef.STORE),
			load = IrSymbol.of(compiler.ir.IrHlScalarRef.LOAD);
		samePass("scalar reference promotion", new IrFunction("Main.reference", [condition, x], I32, [
			block(0, [
				Call(reference, address, [x]),
				Call(stored, store, [reference, x]),
				Call(loaded, load, [reference])
			], Return(loaded))
		], Ordinary), fn -> compiler.ir.IrScalarRefPromotion.run(fn),
			(body, scratch) -> compiler.ir.IrScalarRefPromotion.runBody(body, scratch));
		var receiver = value("receiver", Obj("Point")),
			firstCheck = value("firstCheck", Void),
			secondCheck = value("secondCheck", Void),
			check = IrSymbol.of(compiler.ir.IrReceiverCheck.NAME);
		samePass("receiver check elision", new IrFunction("Main.checks", [condition, x, receiver], I32, [
			block(0, [Call(firstCheck, check, [receiver])], Jump(1)),
			block(1, [Call(secondCheck, check, [receiver])], Return(x))
		], Ordinary), fn -> compiler.ir.IrReceiverCheckElision.run(fn),
			(body, scratch) -> compiler.ir.IrReceiverCheckElision.runBody(body, scratch));
		var point = value("point", Obj("Point")), reloaded = value("reloaded", I32);
		samePass("load-store forwarding", new IrFunction("Main.fields", [condition, x, point], I32, [
			block(0, [FieldSet(point, "x", x), FieldGet(reloaded, point, "x")], Return(reloaded))
		], Ordinary), fn -> compiler.ir.IrLoadStoreForwarding.run(fn),
			(body, scratch) -> compiler.ir.IrLoadStoreForwarding.runBody(body, null, scratch));
		var real = value("real", F64), two = value("two", F64), half = value("half", F64);
		samePass("strength reduction", new IrFunction("Main.halve", [real], F64, [
			block(0, [ConstFloat(two, 2.0), Div(half, real, two)], Return(half))
		], Ordinary), fn -> compiler.ir.IrStrengthReduction.run(fn),
			(body, scratch) -> compiler.ir.IrStrengthReduction.runBody(body));
		scalarReplacement();
		copyElision();
	}

	static function field(name:String, type:IrType, ?nativeSize:Int):IrObjectField
		return nativeSize == null ? {name: name, type: type} : {
			name: name,
			type: type,
			nativeLayout: {
				offset: 0,
				size: nativeSize,
				alignment: nativeSize,
				signed: true,
				inlineRecord: false
			}
		};

	static function object(name:String, isValue:Bool, fields:Array<IrObjectField>):IrObject
		return {
			name: name,
			isValue: isValue,
			base: null,
			interfaces: [],
			fields: fields,
			methods: []
		};

	/**
	 * Scalar replacement with phis, zero defaults and narrowed stores; phis declined, the ids they took skipped; nested values,
	 * one declined and rolled back before another goes through; a fresh value copied into a parent's inline slot, expanded and through `placeInSlot`.
	 */
	static function scalarReplacement():Void {
		nextId = 0;
		var objects = compiler.ir.IrObjectTable.of([
			"Point" => object("Point", true, [field("x", I32, 1), field("y", F32), field("z", I32)]),
			"Inner" => object("Inner", true, [field("a", I32), field("b", I32)]),
			"Outer" => object("Outer", true, [field("inner", Obj("Inner")), field("w", I32)]),
			"Pair" => object("Pair", true, [field("x", I32), field("y", I32)]),
			"Loose" => object("Loose", true, [field("x", I32), field("o", Nullable(Obj("Pair")))]),
			"Holder" => object("Holder", false, [field("pair", Obj("Pair")), field("loose", Obj("Loose"))])
		]);
		var condition = value("condition", Bool),
			x = value("x", I32),
			single = value("single", F32),
			point = value("point", Obj("Point")),
			read = value("read", I32),
			one = value("one", I32),
			bumped = value("bumped", I32),
			readY = value("readY", F32),
			readZ = value("readZ", I32),
			sum = value("sum", I32);
		var loop = new IrFunction("Main.loop", [condition, x, single], I32, [
			block(0, [ValueInit(point), FieldSet(point, "x", x), FieldSet(point, "y", single)], Jump(1)),
			block(1, [FieldGet(read, point, "x")], Branch(condition, 2, 3)),
			block(2, [ConstInt(one, 1), Add(bumped, read, one), FieldSet(point, "x", bumped)], Jump(1)),
			block(3, [FieldGet(readY, point, "y"), FieldGet(readZ, point, "z"), Add(sum, read, readZ)], Return(sum))
		], Ordinary);
		samePass("scalar replacement with phis", loop,
			fn -> compiler.ir.IrScalarReplacement.rewrite(fn, objects, true),
			(body, scratch) -> compiler.ir.IrScalarReplacement.runBody(body, objects, scratch, true));
		var declinedPair = value("declinedPair", Obj("Pair")),
			pairRead = value("pairRead", I32),
			declined = value("declined", Obj("Outer")),
			declinedInner = value("declinedInner", Obj("Inner")),
			joined = value("joined", I32),
			outer = value("outer", Obj("Outer")),
			inner = value("inner", Obj("Inner")),
			a = value("a", I32),
			b = value("b", I32),
			total = value("total", I32);
		var nested = new IrFunction("Main.nested", [condition, x], I32, [
			block(0, [
				ValueInit(declinedPair),
				ValueInit(declined),
				FieldGet(declinedInner, declined, "inner"),
				ValueInit(outer),
				FieldGet(inner, outer, "inner"),
				FieldSet(inner, "a", x),
				FieldGet(a, inner, "a"),
				FieldGet(b, inner, "b"),
				Add(total, a, b)
			], Branch(condition, 1, 2)),
			block(1, [FieldSet(declinedInner, "a", x), FieldSet(declinedPair, "x", x)], Jump(2)),
			block(2, [FieldGet(joined, declinedInner, "a"), FieldGet(pairRead, declinedPair, "x")], Return(total))
		], Ordinary);
		samePass("nested scalar replacement", nested, fn -> compiler.ir.IrScalarReplacement.rewrite(fn, objects),
			(body, scratch) -> compiler.ir.IrScalarReplacement.runBody(body, objects, scratch));
		var holder = value("holder", Obj("Holder")),
			pair = value("pair", Obj("Pair")),
			loose = value("loose", Obj("Loose"));
		var construct = new IrFunction("Main.construct", [holder, x], I32, [
			block(0, [
				ValueInit(pair),
				FieldSet(pair, "x", x),
				FieldSet(holder, "pair", pair),
				ValueInit(loose),
				FieldSet(loose, "x", x),
				FieldSet(holder, "loose", loose)
			], Return(x))
		], Ordinary);
		samePass("construction in place", construct,
			fn -> compiler.ir.IrScalarReplacement.rewrite(fn, objects, false, true),
			(body, scratch) -> compiler.ir.IrScalarReplacement.runBody(body, objects, scratch, false, true));
	}

	/** A value copy passed to a callee that only reads it is replaced by its source; the callees consulted are the same. */
	static function copyElision():Void {
		nextId = 0;
		var parameter = value("parameter", Obj("Pair")), field = value("field", I32);
		var reader = new IrFunction("Main.reader", [parameter], I32, [block(0, [FieldGet(field, parameter, "x")],
			Return(field))], Ordinary);
		var source = value("source", Obj("Pair")),
			copy = value("copy", Obj("Pair")),
			fed = value("fed", I32),
			result = value("result", I32);
		var main = block(0, [], Return(result));
		main.instructions.push(new Located(ValueInit(copy), SourceProvenance.generated("value-copy")));
		for (instruction in [
			FieldGet(fed, source, "x"),
			FieldSet(copy, "x", fed),
			Call(result, IrSymbol.of("Main.reader"), [copy])
		])
			main.instructions.push(new Located(instruction, SourceProvenance.generated("body-pass-test")));
		var fn = new IrFunction("Main.copies", [source], I32, [main], Ordinary);
		var objectConsulted:Array<String> = [], bodyConsulted:Array<String> = [];
		var readerBody = IrBodyBuilder.encode(reader, new IrTypeIds());
		expect(compiler.ir.IrCopyElision.hasCopies(fn.blocks)
			&& compiler.ir.IrCopyElision.hasCopiesBody(IrBodyBuilder.encode(fn, new IrTypeIds()))
			&& !compiler.ir.IrCopyElision.hasCopiesBody(readerBody), "finding value copies");
		samePass("copy elision", fn, function(fn:IrFunction):IrFunction {
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copied = new IrBlock(block.id, block.instructions.copy());
				copied.terminator = block.terminator;
				blocks.push(copied);
			}
			new compiler.ir.IrCopyElision(["Main.reader" => reader], (receiver, method) -> null,
				name -> objectConsulted.push(name)).run(blocks);
			return fn.withBlocks(blocks);
		}, (body, scratch) -> compiler.ir.IrCopyElision.runBody(body, name -> name == "Main.reader" ? readerBody : null,
			(type, method) -> null, name -> bodyConsulted.push(name), scratch));
		expect(objectConsulted.length > 0 && objectConsulted.join(",") == bodyConsulted.join(","),
			"copy elision consults the same callees");
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
