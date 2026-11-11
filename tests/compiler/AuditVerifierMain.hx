import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.ir.IrHlScalarRef;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

class AuditVerifierMain {
	static function verifyLaneArrayInvariant():Void {
		function make(operation:String, element:IrType, valueObject:Bool):IrProgram {
			var builder = new IrBuilder(), array = builder.argument("array", Array(element)),
				index = builder.constInt(0), value = builder.argument("value", element),
				out = new IrValue(1000, "out", element), provenance = SourceProvenance.generated("lane-verifier-test");
			var instruction:IrInstruction = switch operation {
				case "get": ArrayGet(out, array, index);
				case "set": ArraySet(array, index, value);
				case "iterator": IteratorNew(new IrValue(1001, "iterator", Iterator(element)), array);
				case "push": Call(new IrValue(1002, "length", I32), "__array_push_ref", [array, value]);
				case "alias": Call(new IrValue(1002, "length", I32), "$aliased-push", [array, value]);
				case "concat-second": Call(new IrValue(1003, "array", Array(Dyn)), "__array_concat_ref",
					[builder.argument("dynamic", Array(Dyn)), array]);
				default: throw 'Unknown test operation $operation';
			};
			builder.currentBlock().instructions.push(new Located(instruction, provenance));
			builder.returnValue(builder.constInt(0));
			var program = new IrProgram("main");
			program.natives.push({name:"$aliased-push", library:"haxeon_runtime", symbol:"__array_push_ref",
				arguments:[Array(element), element], result:I32});
			program.objects.push({name:"S", isValue:valueObject, base:null, interfaces:[], fields:[], methods:[]});
			program.functions.push(new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary));
			return program;
		}
		for (operation in ["get", "set", "iterator", "push", "alias", "concat-second"]) {
			for (element in [Obj("S"), Nullable(Obj("S"))]) {
				var rejected = false;
				try IrVerifier.verifyValueArraysLowered(make(operation, element, true)) catch (error:String) {
					if (error.indexOf("ordinary array operation on inline value lanes") < 0) throw error;
					rejected = true;
				}
				if (!rejected) throw 'Verifier accepted $operation on $element lanes';
			}
			IrVerifier.verifyValueArraysLowered(make(operation, Obj("S"), false));
			IrVerifier.verifyValueArraysLowered(make(operation, Dyn, true));
		}
	}

	static function rejected(program:IrProgram, expected:String):Void {
		try {
			IrVerifier.verify(program);
		} catch (error:String) {
			if (error.indexOf(expected) >= 0)
				return;
			throw error;
		}
		throw 'Verifier accepted malformed IR: $expected';
	}

	static function typeError(source:String):Void {
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.code == "E1002" || error.diagnostic.code == "E1009")
				return;
			throw error;
		}
		throw "Expected a typed conversion diagnostic";
	}

	static function rejectedFunctions(program:IrProgram, names:Map<String, Bool>, expected:String):Void {
		try {
			IrVerifier.verifyFunctions(program, names);
		} catch (error:String) {
			if (error.indexOf(expected) >= 0)
				return;
			throw error;
		}
		throw 'Selective verifier accepted malformed IR: $expected';
	}

	static function main():Void {
		verifyLaneArrayInvariant();
		var intrinsicBuilder = new IrBuilder(), invalidInput = intrinsicBuilder.argument("value", I32);
		intrinsicBuilder.returnValue(intrinsicBuilder.intrinsic(EnumDynamicBox(Enum("Example")), [invalidInput], Dyn));
		var intrinsicProgram = new IrProgram("main");
		intrinsicProgram.functions.push(new IrFunction("main", intrinsicBuilder.arguments, Dyn, intrinsicBuilder.blocks, Ordinary));
		rejected(intrinsicProgram, "Invalid IR enum Dynamic box signature");
		var dispatchRejected = false;
		try compiler.ir.IrEnumDynamicDispatch.rewrite(intrinsicProgram.functions) catch (error:String) {
			if (error.indexOf("Invalid enum Dynamic box signature") < 0) throw error;
			dispatchRejected = true;
		}
		if (!dispatchRejected) throw "Enum Dynamic dispatch accepted an invalid typed box";
		var validBox = new IrBuilder(), enumInput = validBox.argument("value", Enum("Example"));
		validBox.returnValue(validBox.intrinsic(EnumDynamicBox(Enum("Example")), [enumInput], Dyn));
		var reserved = new IrBuilder(); reserved.returnValue(reserved.constVoid());
		var collision = new IrProgram("main");
		collision.enums = [{name: "Example", cases: [{name: "Only", params: []}]}];
		collision.functions = compiler.ir.IrEnumDynamicDispatch.rewrite([
			new IrFunction("main", validBox.arguments, Dyn, validBox.blocks, Ordinary),
			new IrFunction("$haxeon_enum_dynamic_box_0", reserved.arguments, Void, reserved.blocks, Ordinary)
		]);
		IrVerifier.verify(collision);
		var invalidAdapter = new IrProgram("main");
		invalidAdapter.functions.push(new IrFunction("main", intrinsicBuilder.arguments, Dyn, intrinsicBuilder.blocks,
			EnumTagAdapter(EnumTag("Example"), true)));
		rejected(invalidAdapter, "Invalid enum tag adapter signature");
		var invalidTagBuilder = new IrBuilder(), invalidTagInput = invalidTagBuilder.argument("value", I32);
		invalidTagBuilder.returnValue(invalidTagBuilder.intrinsic(EnumTagBox(EnumTag("Example")), [invalidTagInput], Dyn));
		var invalidTag = new IrProgram("main");
		invalidTag.enums = [{name: "Example", cases: [{name: "Only", params: []}]}];
		invalidTag.functions.push(new IrFunction("main", invalidTagBuilder.arguments, Dyn, invalidTagBuilder.blocks, Ordinary));
		rejected(invalidTag, "Invalid IR enum tag box signature");
		var tagLoweringRejected = false;
		try compiler.ir.IrEnumTagLowering.escapes(invalidTag) catch (error:String) {
			if (error.indexOf("Invalid enum tag box signature") < 0) throw error;
			tagLoweringRejected = true;
		}
		if (!tagLoweringRejected) throw "Enum tag lowering accepted an invalid typed box";
		var refBuilder = new IrBuilder(), initialValue = refBuilder.constInt(0),
			stackRef = refBuilder.call(IrHlScalarRef.ADDRESS, [initialValue], IrHlScalarRef.type(I32));
		refBuilder.returnValue(stackRef);
		var refProgram = new IrProgram("main");
		refProgram.functions.push(new IrFunction("main", [], stackRef.type, refBuilder.blocks, Ordinary));
		rejected(refProgram, "scalar stack reference cannot be returned");

		var builder = new IrBuilder(),
			condition = builder.argument("condition", Bool),
			yes = builder.createBlock(),
			no = builder.createBlock();
		builder.branch(condition, yes, no);
		builder.select(no);
		var value = builder.constInt(42);
		builder.returnValue(value);
		builder.select(yes);
		builder.returnValue(value);
		var program = new IrProgram("main");
		program.functions.push(new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary));
		rejected(program, "does not dominate");

		var forged = new IrBuilder(), integer = forged.constInt(42);
		forged.returnValue(new IrValue(integer.id, "forged", Bool));
		var forgedProgram = new IrProgram("main");
		forgedProgram.functions.push(new IrFunction("main", [], Bool, forged.blocks, Ordinary));
		rejected(forgedProgram, "definition type");

		var phiBuilder = new IrBuilder(),
			flag = phiBuilder.argument("flag", Bool),
			left = phiBuilder.createBlock(),
			right = phiBuilder.createBlock(),
			join = phiBuilder.createBlock();
		phiBuilder.branch(flag, left, right);
		phiBuilder.select(left);
		var leftValue = phiBuilder.constInt(42);
		phiBuilder.jump(join);
		phiBuilder.select(right);
		phiBuilder.jump(join);
		phiBuilder.select(join);
		var merged = phiBuilder.phi(I32, [{block: left.id, value: leftValue}, {block: right.id, value: leftValue}]);
		phiBuilder.returnValue(merged);
		var phiProgram = new IrProgram("main");
		phiProgram.functions.push(new IrFunction("main", phiBuilder.arguments, I32, phiBuilder.blocks, Ordinary));
		rejected(phiProgram, "does not dominate");

		var critical = new IrBuilder(),
			criticalFlag = critical.argument("flag", Bool),
			initial = critical.constInt(1),
			other = critical.createBlock(),
			criticalJoin = critical.createBlock();
		critical.branch(criticalFlag, criticalJoin, other);
		critical.select(other);
		var alternative = critical.constInt(42);
		critical.jump(criticalJoin);
		critical.select(criticalJoin);
		critical.returnValue(critical.phi(I32, [{block: 0, value: initial}, {block: other.id, value: alternative}]));
		var criticalProgram = new IrProgram("main"),
			criticalFunction = new IrFunction("main", critical.arguments, I32, critical.blocks, Ordinary);
		criticalProgram.functions.push(criticalFunction);
		var before = compiler.ir.codec.IrFunctionStateCodec.encode(criticalFunction);
		compiler.ir.hl.HlLower.lower(criticalProgram);
		if (before.compare(compiler.ir.codec.IrFunctionStateCodec.encode(criticalFunction)) != 0)
			throw "Phi edge splitting mutated cached SSA";
		IrVerifier.verify(criticalProgram);

		var cached = new IrBuilder(), cachedValue = cached.constInt(1);
		cached.returnValue(cachedValue);
		var invalid = new IrBuilder(), invalidValue = invalid.constInt(2);
		invalid.returnValue(new IrValue(invalidValue.id, "forged", Bool));
		var selectiveProgram = new IrProgram("cached");
		selectiveProgram.functions.push(new IrFunction("cached", [], I32, cached.blocks, Ordinary));
		selectiveProgram.functions.push(new IrFunction("edited", [], Bool, invalid.blocks, Ordinary));
		IrVerifier.verifyFunctions(selectiveProgram, ["cached" => true]);
		rejectedFunctions(selectiveProgram, ["edited" => true], "definition type");

		typeError('function f(value:Dynamic):Int return 42; function main():Int { var g:(Int)->Int = f; return g("wrong"); }');
		typeError('function main():Int { var a:Array<Int> = [42]; var b:Array<Dynamic> = a; return 42; }');
		typeError('function main():Int { var a:Array<Int> = [42]; var b:Array<Null<Int>> = a; return 42; }');
		Sys.println("PASS: SSA dominance, edge uses, canonical types, and typed conversion diagnostics");
	}
}
