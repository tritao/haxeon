import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueArrayLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.IrVerifier;
import compiler.ir.codec.CanonicalIrCodec;

@:access(compiler.ir.IrBuilder)
class InlineEnumArrayLayoutMain {
	static function main():Void {
		for (target in [HashLink, Wasm32, WasmGc]) {
			var declaration:IrEnum = {name:"Element", cases:[{name:"Empty", params:[]}, {name:"Value", params:[I32, Bytes]}]};
			var planner = new IrInlineEnumLayout([declaration], [], target == HashLink ? 64 : 32, target);
			var shape = planner.shape(declaration.name);
			if (shape == null) throw "Expected inline element";
			var program = new IrProgram("main"), body = new IrBuilder(); body.returnValue(body.constInt(42));
			program.functions = [new IrFunction("main", body.arguments, I32, body.blocks)];
			program.objects = planner.generatedObjects();
			program.enums = [{name:declaration.name, cases:declaration.cases, isRecursive:false, inlineStorage:shape.valueObject.name}];
			var inlineAbi = compiler.abi.RuntimeAbi.describe(program);
			var boxed = CanonicalIrCodec.decode(CanonicalIrCodec.encode(program));
			boxed.enums = [declaration];
			var boxedAbi = compiler.abi.RuntimeAbi.describe(boxed);
			if (boxedAbi.enums.get(declaration.name) != "Empty();Value(I32,Bytes)")
				throw "Boxed enum ABI signatures must remain unchanged";
			for (pair in [[boxedAbi, inlineAbi], [inlineAbi, boxedAbi]]) {
				switch compiler.abi.PatchPlanner.plan(pair[0], pair[1]) {
					case ReloadDomain([EnumChanged(name)]) if (name == declaration.name):
					default: throw "Changing enum storage must reload the domain";
				}
			}
			var unchanged = CanonicalIrCodec.decode(CanonicalIrCodec.encode(program));
			var edited = new IrBuilder(); edited.returnValue(edited.constInt(43));
			unchanged.functions = [new IrFunction("main", edited.arguments, I32, edited.blocks)];
			switch compiler.abi.PatchPlanner.plan(inlineAbi, compiler.abi.RuntimeAbi.describe(unchanged)) {
				case Patch:
				default: throw "A body edit with unchanged enum storage must remain patchable";
			}
			var obsolete = CanonicalIrCodec.encode(program);
			obsolete.set(3, CanonicalIrCodec.VERSION - 1);
			rejected(() -> { CanonicalIrCodec.decode(obsolete); }, "Unsupported canonical Haxeon IR version");
			for (candidate in [program, CanonicalIrCodec.decode(CanonicalIrCodec.encode(program))]) {
				var objects = IrObjectTable.of([for (object in candidate.objects) object.name => object]);
				for (logical in [Enum(declaration.name)]) {
					var layout = new IrValueArrayLayout(objects, logical, target == HashLink ? 64 : 32, target, candidate.enums);
					if (!IrVerifier.sameType(layout.element, logical)
						|| !IrVerifier.sameType(layout.storage, Obj(shape.valueObject.name)) || layout.hasValidity)
						throw "A public enum array must retain its logical type and use tag zero for null";
					if (layout.lanes.references != 1 || layout.scalarStorageWords(4) != 8 || layout.referenceStorageSlots(4) != 4)
						throw "Enum arrays must store complete tag/scalar/reference lanes without an optional wrapper";
				}
			}
			var sourceOptional = compiler.types.Type.CompilerType.TNullable(
				compiler.types.Type.CompilerType.TInstance(compiler.types.Type.NominalKind.Enum, declaration.name, []));
			if (!IrVerifier.sameType(new compiler.ir.IrGenerator(compiler.ir.ProgramFacts.empty(), compiler.ir.TargetProfile.portable).lowerType(sourceOptional), Enum(declaration.name))
				|| !IrVerifier.sameType(new compiler.ir.IrGenerator(compiler.ir.ProgramFacts.empty(), compiler.ir.TargetProfile.portable).lowerType(compiler.types.Type.CompilerType.TArray(sourceOptional)), Array(Enum(declaration.name))))
				throw "Source Null<E> must use the enum's existing null-capable IR type";
			var objectTable = IrObjectTable.of([for (object in program.objects) object.name => object]);
			rejected(() -> { new IrValueArrayLayout(objectTable, Nullable(Enum(declaration.name)), 64, target, program.enums); }, "canonical Enum IR type");
			program.staticFields = [{name:"unrelatedOptional", type:Nullable(I32)}];
			var erased = compiler.ir.IrNullableErasure.run(program);
			if (erased == program || erased.enums[0].inlineStorage != shape.valueObject.name || erased.enums[0].isRecursive != false)
				throw "Nullable erasure must preserve enum recursion classification and storage";
			IrVerifier.verify(erased);
			var closures = CanonicalIrCodec.decode(CanonicalIrCodec.encode(program));
			var callback = new IrBuilder(), payload = callback.argument("payload", Obj(shape.valueObject.name));
			callback.returnValue(callback.fieldGet(payload, "tag", I32));
			var invoke = new IrBuilder(), argument = invoke.argument("payload", Obj(shape.valueObject.name));
			var closure = invoke.staticClosure("callback", Function([argument.type], I32));
			invoke.returnValue(invoke.callClosure(closure, [argument], I32));
			closures.functions = [new IrFunction("main", invoke.arguments, I32, invoke.blocks),
				new IrFunction("callback", callback.arguments, I32, callback.blocks)];
			compiler.ir.IrScalarArguments.rewrite(closures);
			compiler.ir.IrScalarClosures.rewrite(closures);
			if (closures.enums[0].inlineStorage != shape.valueObject.name || closures.enums[0].isRecursive != false)
				throw "Closure ABI rewriting must preserve enum layout classification and storage";
			for (nullable in [false, true]) for (operation in 0...4) {
				var bad = new IrBuilder(), element:IrType = nullable ? Nullable(Enum(declaration.name)) : Enum(declaration.name);
				var array = bad.argument("array", Array(element)), index = bad.constInt(0), value = bad.constNull(element);
				switch operation {
					case 0: bad.emit(ArrayGet(bad.temporary(element), array, index));
					case 1: bad.emit(ArraySet(array, index, value));
					case 2: bad.emit(IteratorNew(bad.temporary(Iterator(element)), array));
					case 3:
						bad.call("ordinary", [array, index], element);
						program.natives = [{name:"ordinary", library:"haxeon_runtime", symbol:"__array_get_ref", arguments:[Array(element), I32], result:element}];
				}
				bad.returnValue(bad.constInt(42));
				program.functions = [new IrFunction("main", bad.arguments, I32, bad.blocks)];
				rejected(() -> IrVerifier.verifyValueArraysLowered(program), "ordinary array operation on inline value lanes");
			}
			program.functions = [new IrFunction("main", body.arguments, I32, body.blocks)]; program.natives = [];
			var storage = program.enums[0].inlineStorage;
			for (bad in ["Missing", "Element", "$inline-enum:Other"]) {
				program.enums = [{name:declaration.name, cases:declaration.cases, inlineStorage:bad}];
				rejected(() -> IrVerifier.verify(program), "Invalid inline storage");
			}
			program.enums = [{name:declaration.name, cases:declaration.cases, inlineStorage:storage, isRecursive:true}];
			rejected(() -> IrVerifier.verify(program), "Invalid inline storage");
			program.enums = [declaration];
			var objects = IrObjectTable.of([for (object in program.objects) object.name => object]);
			rejected(() -> { new IrValueArrayLayout(objects, Enum(declaration.name), 64, target, program.enums); }, "has no inline storage");
		}
		Sys.println("PASS: enum array logical/storage types and null tags survive canonical IR on all targets");
	}

	static function rejected(run:Void->Void, expected:String):Void {
		var error = ""; try run() catch (caught:Dynamic) error = Std.string(caught);
		if (error.indexOf(expected) < 0) throw 'Expected "$expected", got "$error"';
	}
}
