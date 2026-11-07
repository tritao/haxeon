import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrValueLaneLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.IrValueArrayLayout;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrValueArrayAccess;
import compiler.ir.IrValueArraySlotHelpers;
import compiler.ir.IrObjectTable;
import compiler.ir.IrOptionalFieldStorage;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
import compiler.backend.wasm.WasmTarget;

/** Inline nullable payloads retain every reference and nested presence flag in their holder's layout. */
class InlineValueLayoutMain {
	static function main():Void {
		var objects:Map<String, IrObject> = [];
		objects.set("Child", {
			name: "Child", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "x", type: I32}, {name: "label", type: Bytes}]
		});
		objects.set("Value", {
			name: "Value", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "child", type: Nullable(Obj("Child"))}, {name: "owner", type: Obj("Owner")}]
		});
		objects.set("Owner", {
			name: "Owner", isValue: false, base: null, interfaces: [], methods: [], fields: [{name: "value", type: Obj("Value")}]
		});
		var slots = new IrInlineValueLayout(IrObjectTable.of(objects)).slots(Nullable(Obj("Value")));
		var expected = [":present:Bool", "child:present:Bool", "child.x:value:I32", "child.label:value:Bytes", "owner:value:Obj(Owner)"];
		var actual = [for (slot in slots) slot.path.join(".") + (slot.isPresence ? ":present:" : ":value:") + Std.string(slot.type)];
		if (actual.join(",") != expected.join(","))
			throw 'Wrong inline value slots: ${actual.join(",")}';
		var lanes = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(Nullable(Obj("Value")));
		if (lanes.scalarWordBits != 32 || lanes.scalarWords != 2 || lanes.references != 2)
			throw "nested optional values must share one scalar lane and one reference lane";
		if (!lanes.slots[0].isPresence || lanes.slots[0].bitOffset != 0 || !lanes.slots[1].isPresence
			|| lanes.slots[1].bitOffset != 8 || lanes.slots[2].index != 1 || lanes.slots[2].bitWidth != 32
			|| !lanes.slots[3].isReference || lanes.slots[3].index != 0 || !lanes.slots[4].isReference || lanes.slots[4].index != 1)
			throw "nested optional leaves must address their own packed scalar and reference slots";
		var nestedHelpers = new IrValueArraySlotHelpers(Nullable(Obj("Value")), lanes);
		var parentCheck = nestedHelpers.checker(["child"], false), childCheck = nestedHelpers.checker(["child"], true);
		var checkCounts:Map<String, Int> = [];
		var nestedFunctions = nestedHelpers.functions();
		for (fn in nestedFunctions) if (fn.name == parentCheck || fn.name == childCheck) {
			var count = 0;
			for (block in fn.blocks) if (block.terminator != null) switch block.terminator.value {
				case Branch(_, _, _): count++;
				default:
			}
			checkCounts.set(fn.name, count);
		}
		if (checkCounts.get(parentCheck) != 1 || checkCounts.get(childCheck) != 2)
			throw "a place check must validate each nullable ancestor and only check the selected field when dereferencing it";
		var nestedCheckProgram = new IrProgram(parentCheck);
		nestedCheckProgram.objects = [objects.get("Value"), objects.get("Child"), objects.get("Owner")];
		nestedCheckProgram.functions = nestedFunctions;
		nestedCheckProgram.natives = nestedHelpers.natives();
		IrVerifier.verify(nestedCheckProgram);
		compiler.ir.hl.HlLower.lower(nestedCheckProgram);
		objects.set("Mixed", {
			name: "Mixed", isValue: true, base: null, interfaces: [], methods: [],
			fields: [
				{name: "tag", type: I32, scalarStorage: {size: 1, signed: false}},
				{name: "delta", type: I32, scalarStorage: {size: 2, signed: true}},
				{name: "optional", type: Nullable(I32)}, {name: "ratio", type: F64}, {name: "owner", type: Bytes}
			]
		});
		var mixed = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(Obj("Mixed"));
		if (mixed.scalarWordBits != 64 || mixed.scalarWords != 2 || mixed.references != 1
			|| mixed.slots[0].bitWidth != 8 || mixed.slots[1].bitOffset != 8 || !mixed.slots[1].signed
			|| !mixed.slots[2].isPresence || mixed.slots[2].bitOffset != 24
			|| !mixed.slots[3].nullablePayload || mixed.slots[3].bitOffset != 32 || mixed.slots[4].index != 1
			|| !mixed.slots[5].isReference)
			throw "mixed values must pack narrow scalars and optional payloads alongside one reference lane";
		var lanePlanProgram = new IrProgram("main"), laneMain = new IrBuilder();
		laneMain.returnValue(laneMain.constInt(42));
		lanePlanProgram.objects = [objects.get("Mixed")];
		lanePlanProgram.functions = [new IrFunction("main", laneMain.arguments, I32, laneMain.blocks)];
		lanePlanProgram.natives = [{name: "$value-array:test-allocate", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: Array(Obj("Mixed"))}];
		var lanePlan = new compiler.backend.wasm.gc.WasmGcTypePlan(lanePlanProgram),
			laneModule = new compiler.backend.wasm.WasmModule.WasmModule("value-array-plan");
		lanePlan.addTo(laneModule);
		var baseArray = lanePlan.arrayType(Obj("Mixed")), valueWrapper = laneModule.typeAt(lanePlan.valueArrayWrapperTypeIndex);
		var valueFields = switch valueWrapper.composite { case Struct(fields): fields; default: throw "Value array wrapper must be a struct"; };
		var referenceField = switch valueFields[compiler.backend.wasm.gc.WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD].type {
			case Value(Ref(ref)): ref.nullable && ref.heap == compiler.backend.wasm.WasmTypes.WasmHeapType.Array;
			default: false;
		};
		if (laneModule.typeAt(baseArray).finalType || valueWrapper.supertypes.length != 1 || valueWrapper.supertypes[0] != baseArray
			|| valueFields.length != 13 || !referenceField || lanePlan.valueArrayI32LaneTypeIndex < 0
			|| lanePlan.valueArrayI64LaneTypeIndex < 0 || lanePlan.valueArrayReferenceLaneTypeIndex < 0 || lanePlan.valueArrayForwardLaneTypeIndex < 0)
			throw "Wasm GC value arrays must subtype the shared array wrapper and plan their scalar and reference lanes";
		var scalar32 = switch laneModule.typeAt(lanePlan.valueArrayI32LaneTypeIndex).composite { case Array(field): field.type; default: null; };
		var scalar64 = switch laneModule.typeAt(lanePlan.valueArrayI64LaneTypeIndex).composite { case Array(field): field.type; default: null; };
		var refLane = switch laneModule.typeAt(lanePlan.valueArrayReferenceLaneTypeIndex).composite { case Array(field): field.type; default: null; };
		var scalar32Correct = switch scalar32 { case Value(I32): true; default: false; };
		var scalar64Correct = switch scalar64 { case Value(I64): true; default: false; };
		var refLaneCorrect = switch refLane {
			case Value(Ref(ref)): ref.nullable && ref.heap == compiler.backend.wasm.WasmTypes.WasmHeapType.Any;
			default: false;
		};
		if (!scalar32Correct || !scalar64Correct || !refLaneCorrect) throw "Wasm GC lane arrays must have the planned word and reference types";
		compiler.backend.wasm.WasmValidator.validate(laneModule);
		lanePlanProgram.natives = [];
		lanePlanProgram.staticFields = [{name: "array", type: Array(Obj("Mixed"))}];
		var ordinaryPlan = new compiler.backend.wasm.gc.WasmGcTypePlan(lanePlanProgram),
			ordinaryModule = new compiler.backend.wasm.WasmModule.WasmModule("ordinary-array-plan");
		ordinaryPlan.addTo(ordinaryModule);
		if (ordinaryPlan.valueArrayWrapperTypeIndex >= 0 || !ordinaryModule.typeAt(ordinaryPlan.arrayType(Obj("Mixed"))).finalType)
			throw "Programs without inline value arrays must retain the ordinary array type plan";
		var mixedHelpers = new IrValueArraySlotHelpers(Obj("Mixed"), mixed);
		if (mixedHelpers.slot(["optional"], true) != 2 || mixedHelpers.slot(["optional"], false, true) != 3
			|| mixedHelpers.slot(["owner"]) != 5)
			throw "a lane place must distinguish optional flags, payloads and reference fields";
		var optionalCheck = mixedHelpers.checker(["optional"], true);
		var checkProgram = new IrProgram(optionalCheck);
		checkProgram.objects = [objects.get("Mixed")];
		checkProgram.functions = mixedHelpers.functions();
		checkProgram.natives = mixedHelpers.natives();
		IrVerifier.verify(checkProgram);
		compiler.ir.hl.HlLower.lower(checkProgram);
		var access = new IrValueArrayAccess(mixed.scalarWordBits), accessBuilder = new IrBuilder();
		var accessArray = accessBuilder.argument("array", Array(Obj("Mixed"))), accessIndex = accessBuilder.argument("index", I32),
			accessValue = accessBuilder.argument("value", I32), accessOwner = accessBuilder.argument("owner", Bytes);
		access.write(accessBuilder, accessArray, accessIndex, mixed.slots[1], accessValue);
		access.write(accessBuilder, accessArray, accessIndex, mixed.slots[5], accessOwner);
		var restoredValue = access.read(accessBuilder, accessArray, accessIndex, mixed.slots[1]);
		access.read(accessBuilder, accessArray, accessIndex, mixed.slots[5]);
		accessBuilder.returnValue(restoredValue);
		var accessProgram = new IrProgram("access");
		accessProgram.objects = [objects.get("Mixed")];
		accessProgram.functions = [new IrFunction("access", accessBuilder.arguments, I32, accessBuilder.blocks)];
		accessProgram.natives = access.natives();
		IrVerifier.verify(accessProgram);
		compiler.ir.hl.HlLower.lower(accessProgram);
		var specialized = new compiler.backend.wasm.gc.WasmGcValueArrayAccessors(accessProgram), scalarAccessCount = 0;
		IrVerifier.verify(specialized.program);
		specialized.program.natives.push({name:"$value-array:scalar-test-plan", library:"haxeon_runtime", symbol:"__value_array_alloc",
			arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)});
		for (name => spec in specialized.accesses) {
			scalarAccessCount++;
			if (spec.strideBits != mixed.scalarStrideBits || spec.wordBits != mixed.scalarWordBits || spec.offsetBits != 8
					|| spec.widthBits != 16 || !spec.hasValidity) throw "typed array access lost its layout";
			var native = [for (n in specialized.program.natives) if (n.name == name) n][0];
			if (native.arguments.length != (native.result == Void ? 3 : 2)) throw "constant slot metadata must not be passed at runtime";
			var module = new compiler.backend.wasm.WasmModule.WasmModule("typed-scalar-access"),
				plan = new compiler.backend.wasm.gc.WasmGcTypePlan(specialized.program);
			plan.addTo(module);
			var accessor = compiler.backend.wasm.gc.WasmGcScalarArrayAccess.build(plan, native, false, spec), laneCasts = 0;
			for (instruction in accessor.body) switch instruction {
				case Loop(_), I64DivS, I64RemS: throw "a typed scalar place must access words without byte loops or runtime division";
				case RefCast(reference): switch reference.heap {
					case Type(index) if (index == plan.valueArrayI64LaneTypeIndex): laneCasts++;
					default:
				}
				default:
			}
			if (laneCasts != 1) throw "a typed scalar place must cast its lane once";
		}
		if (scalarAccessCount != 2) throw "expected one typed read and write accessor";
		if (accessProgram.natives.length == specialized.program.natives.length) throw "scalar specialization must preserve its input program";
		objects.set("Pointers", {
			name: "Pointers", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "address", type: RawPtr}, {name: "owner", type: Bytes}]
		});
		var pointer32 = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Obj("Pointers"));
		var pointer64 = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(Obj("Pointers"));
		if (pointer32.scalarWordBits != 32 || pointer32.slots[0].bitWidth != 32
			|| pointer64.scalarWordBits != 64 || pointer64.slots[0].bitWidth != 64 || pointer64.references != 1)
			throw "unmanaged pointer slots must follow the selected target width";
		objects.set("NativeHandles", {
			name: "NativeHandles", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "callback", type: Abstract("native_callback")}, {name: "type", type: TypeRef}]
		});
		var hlHandles = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(Obj("NativeHandles"));
		var wasmHandles = new IrValueLaneLayout(IrObjectTable.of(objects), 32, WasmGc).shape(Obj("NativeHandles"));
		if (!hlHandles.slots[0].isReference || hlHandles.slots[1].bitWidth != 64 || hlHandles.references != 1
			|| wasmHandles.slots[0].isReference || wasmHandles.slots[0].bitWidth != 32 || wasmHandles.slots[1].bitWidth != 32
			|| wasmHandles.references != 0)
			throw "native callback and type handles must follow the target's GC representation";
		objects.set("References", {
			name: "References", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "a", type: Bytes}, {name: "b", type: Obj("Owner")}]
		});
		var references = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(Obj("References"));
		if (references.scalarWords != 0 || references.references != 2)
			throw "reference-only values must not allocate an empty scalar lane";
		if (IrValueLaneLayout.referenceStorageSlots(references, 17) != 34)
			throw "reference lane capacity must include each element's slots";
		var referenceOverflowRejected = false;
		try IrValueLaneLayout.referenceStorageSlots(references, 0x7fffffff) catch (_:Dynamic) referenceOverflowRejected = true;
		if (!referenceOverflowRejected) throw "oversized reference lanes must fail without integer overflow";
		objects.set("FlatBytes", {
			name: "FlatBytes", isValue: true, base: null, interfaces: [], methods: [],
			nativeLayout: {target: "portable-abi32", size: 3, alignment: 1},
			fields: [
				{name: "a", type: I32, nativeLayout: {offset: 0, size: 1, alignment: 1, signed: false, inlineRecord: false}},
				{name: "b", type: I32, nativeLayout: {offset: 1, size: 1, alignment: 1, signed: false, inlineRecord: false}},
				{name: "c", type: I32, nativeLayout: {offset: 2, size: 1, alignment: 1, signed: false, inlineRecord: false}}
			]
		});
		var flat = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Obj("FlatBytes"));
		if (!flat.cLayout || flat.scalarWordBits != 32 || flat.scalarStrideBits != 24 || flat.scalarWords != 1
			|| flat.slots[1].bitOffset != 8 || flat.slots[2].bitOffset != 16)
			throw "Flat array elements must retain their C field offsets and exact byte stride";
		if (IrValueLaneLayout.scalarStorageWords(flat, 0) != 0 || IrValueLaneLayout.scalarStorageWords(flat, 4) != 3
			|| IrValueLaneLayout.scalarStorageWords(flat, 5) != 4)
			throw "scalar lane capacity must account for Flat elements sharing words";
		var flatArray = new IrValueArrayLayout(IrObjectTable.of(objects), Obj("FlatBytes"), 32, Wasm32);
		var nullableFlatArray = new IrValueArrayLayout(IrObjectTable.of(objects), Nullable(Obj("FlatBytes")), 32, Wasm32);
		var referenceArray = new IrValueArrayLayout(IrObjectTable.of(objects), Obj("References"), 32, Wasm32);
		if (!flatArray.hasValidity || flatArray.validityWordOffset(4) != 3 || flatArray.scalarStorageWords(4) != 4
			|| nullableFlatArray.hasValidity || nullableFlatArray.scalarStorageWords(4) != 4
			|| !referenceArray.hasValidity || referenceArray.scalarStorageWords(4) != 1 || referenceArray.referenceStorageSlots(4) != 8)
			throw "array validity must share the scalar lane and distinguish unwritten non-null elements";
		var overflowRejected = false;
		try IrValueLaneLayout.scalarStorageWords(mixed, 0x7fffffff) catch (_:Dynamic) overflowRejected = true;
		if (!overflowRejected) throw "oversized scalar lanes must fail without integer overflow";
		objects.set("FlatPadded", {
			name: "FlatPadded", isValue: true, base: null, interfaces: [], methods: [],
			nativeLayout: {target: "portable-abi32", size: 6, alignment: 2},
			fields: [
				{name: "a", type: I32, nativeLayout: {offset: 0, size: 1, alignment: 1, signed: false, inlineRecord: false}},
				{name: "b", type: I32, nativeLayout: {offset: 2, size: 2, alignment: 2, signed: true, inlineRecord: false}},
				{name: "c", type: I32, nativeLayout: {offset: 4, size: 1, alignment: 1, signed: false, inlineRecord: false}}
			]
		});
		var padded = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Obj("FlatPadded"));
		if (padded.scalarStrideBits != 48 || padded.scalarWords != 2 || padded.slots[1].bitOffset != 16
			|| padded.slots[2].index != 1 || padded.slots[2].bitOffset != 0)
			throw "Flat lane layouts must preserve C padding between fields and at the end of each element";
		var optionalFlat = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Nullable(Obj("FlatPadded")));
		if (optionalFlat.cLayout || optionalFlat.scalarStrideBits != 64 || !optionalFlat.slots[0].isPresence
			|| optionalFlat.slots[1].bitOffset != 16 || optionalFlat.slots[2].index != 1)
			throw "optional Flat values must align their C-layout payload after the presence flag";
		objects.set("ContainingFlat", {
			name: "ContainingFlat", isValue: true, base: null, interfaces: [], methods: [],
			fields: [
				{name: "prefix", type: I32, scalarStorage: {size: 1, signed: false}},
				{name: "child", type: Obj("FlatPadded")}, {name: "tail", type: I32, scalarStorage: {size: 1, signed: false}},
				{name: "owner", type: Bytes}
			]
		});
		var containing = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Obj("ContainingFlat"));
		if (containing.cLayout || containing.scalarStrideBits != 96 || containing.references != 1
			|| containing.slots[1].bitOffset != 16 || containing.slots[2].index != 1 || containing.slots[2].bitOffset != 0
			|| containing.slots[3].index != 1 || containing.slots[3].bitOffset != 16
			|| containing.slots[4].index != 2 || containing.slots[4].bitOffset != 0)
			throw "a Flat value inside a managed value must retain its aligned C layout and padding";
		objects.set("FlatNested", {
			name: "FlatNested", isValue: true, base: null, interfaces: [], methods: [],
			nativeLayout: {target: "portable-abi32", size: 10, alignment: 2},
			fields: [
				{name: "prefix", type: I32, nativeLayout: {offset: 0, size: 1, alignment: 1, signed: false, inlineRecord: false}},
				{name: "child", type: Obj("FlatPadded"), nativeLayout: {offset: 2, size: 6, alignment: 2, signed: false, inlineRecord: true}},
				{name: "tail", type: I32, nativeLayout: {offset: 8, size: 1, alignment: 1, signed: false, inlineRecord: false}}
			]
		});
		var nestedFlat = new IrValueLaneLayout(IrObjectTable.of(objects), 32, Wasm32).shape(Obj("FlatNested"));
		if (nestedFlat.scalarStrideBits != 80 || nestedFlat.slots[1].bitOffset != 16 || nestedFlat.slots[2].index != 1
			|| nestedFlat.slots[2].bitOffset != 0 || nestedFlat.slots[4].index != 2)
			throw "nested Flat field offsets must accumulate within the enclosing C record";
		var names:Map<String, Bool> = [];
		for (slot in slots) {
			var name = IrInlineValueLayout.slotName("field", slot);
			if (names.exists(name)) throw 'Duplicate inline slot "$name"';
			names.set(name, true);
		}
		var lowering = new IrOptionalFieldStorage([for (object in objects) object]);
		if (!lowering.hasFields()) throw "missing nullable field storage plan";
		var physical = lowering.physicalObjects([objects.get("Value")])[0];
		if (physical.fields.length != 4) throw 'wrong nullable field storage: ${physical.fields.length}';
		var builder = new IrBuilder(), holder = builder.newObject("Value"), child = builder.newObject("Child");
		builder.fieldSet(child, "x", builder.constInt(42));
		builder.fieldSet(child, "label", builder.constString("kept"));
		builder.fieldSet(holder, "child", builder.toDyn(child, Nullable(Obj("Child"))));
		var read = builder.safeCast(builder.fieldGet(holder, "child", Nullable(Obj("Child"))), Obj("Child"));
		var x = builder.fieldGet(read, "x", I32);
		builder.fieldSet(holder, "child", builder.constNull(Nullable(Obj("Child"))));
		var after = builder.fieldGet(holder, "child", Nullable(Obj("Child"))), yes = builder.createBlock(), no = builder.createBlock();
		builder.branch(builder.equal(after, builder.constNull(Nullable(Obj("Child")))), yes, no);
		builder.select(yes);
		var childSlots = new IrInlineValueLayout(IrObjectTable.of(objects)).slots(Nullable(Obj("Child")));
		var payloadX = builder.fieldGet(holder, IrInlineValueLayout.slotName("child", childSlots[1]), I32);
		var cleared = builder.createBlock();
		builder.branch(builder.equal(payloadX, builder.constInt(0)), cleared, no);
		builder.select(cleared);
		var payloadLabel = builder.fieldGet(holder, IrInlineValueLayout.slotName("child", childSlots[2]), Bytes);
		var success = builder.createBlock();
		builder.branch(builder.equal(payloadLabel, builder.constNull(Bytes)), success, no);
		builder.select(success);
		builder.returnValue(x);
		builder.select(no);
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.objects = lowering.physicalObjects([for (object in objects) object]);
		program.functions = lowering.rewrite([new IrFunction("main", [], I32, builder.blocks)]);
		IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "nullable inline field did not retain and clear its value";
		var referenceBuilder = new IrBuilder(), original = referenceBuilder.newObject("LaneReferenceObject");
		if (!IrValueLaneReference.isCarrier(IrValueLaneReference.type())
			|| IrValueLaneReference.isCarrier(Abstract("native_callback"))
			|| !IrValueLaneReference.canCarry(Abstract("native_callback")))
			throw "the internal lane carrier must remain distinct from managed abstract references";
		var carrier = referenceBuilder.call(IrValueLaneReference.PACK, [original], IrValueLaneReference.type());
		var restored = referenceBuilder.call(IrValueLaneReference.UNPACK, [carrier], Obj("LaneReferenceObject"));
		var same = referenceBuilder.createBlock(), different = referenceBuilder.createBlock();
		referenceBuilder.branch(referenceBuilder.equal(original, restored), same, different);
		referenceBuilder.select(same); referenceBuilder.returnValue(referenceBuilder.constInt(42));
		referenceBuilder.select(different); referenceBuilder.returnValue(referenceBuilder.constInt(0));
		var referenceProgram = new IrProgram("main");
		referenceProgram.objects = [{name: "LaneReferenceObject", isValue: false, base: null, interfaces: [], fields: [], methods: []}];
		referenceProgram.functions = [new IrFunction("main", [], I32, referenceBuilder.blocks)];
		IrVerifier.verify(referenceProgram);
		if (new IrInterpreter(referenceProgram).run() != 42) throw "lane reference casts must preserve identity";
		var hlCode = compiler.ir.hl.HlLower.lower(referenceProgram), casts = 0;
		for (fn in hlCode.functions) for (opcode in fn.opcodes) switch opcode {
			case UnsafeCast(_, _): casts++;
			default:
		}
		if (casts != 2) throw "HashLink lane reference casts must not box";
		new compiler.backend.wasm.WasmBackend().compile(referenceProgram, {target: Wasm32, debugNames: true});
		new compiler.backend.wasm.WasmBackend().compile(referenceProgram, {target: WasmGc, debugNames: true});
		var bridgeClosureType:IrType = Function([], I32), bridgeClosureName = "$value-array:bridge:allocation-test",
			bridgeBody = new IrBuilder(), bridgeMain = new IrBuilder();
		bridgeBody.returnValue(bridgeBody.constInt(21));
		var firstClosure = bridgeMain.staticClosure(bridgeClosureName, bridgeClosureType),
			secondClosure = bridgeMain.staticClosure(bridgeClosureName, bridgeClosureType),
			firstResult = bridgeMain.callClosure(firstClosure, [], I32), secondResult = bridgeMain.callClosure(secondClosure, [], I32);
		bridgeMain.returnValue(bridgeMain.add(firstResult, secondResult));
		var bridgeProgram = new IrProgram("main");
		bridgeProgram.functions = [new IrFunction("main", [], I32, bridgeMain.blocks), new IrFunction(bridgeClosureName, [], I32, bridgeBody.blocks)];
		var bridgeBytes = new compiler.backend.wasm.WasmBackend().compile(bridgeProgram,
			{target: WasmGc, debugNames: true, wasmGcAllocationCount: true}).bytes;
		// These synthetic native descriptors deliberately exercise layouts unrelated to Mixed.
		// Keep their array view untyped; typed places carry an exact compiler-known lane layout.
		var allocationType:IrType = Array(Dyn), readClosureType:IrType = Function([allocationType, I32], Dyn),
			writeClosureType:IrType = Function([allocationType, I32, Dyn, Bool], Void), acceptsClosureType:IrType = Function([Dyn], Bool),
			allocationBuilder = new IrBuilder(), arrays:Array<compiler.ir.Ir.IrValue> = [];
		var readName = "$value-array:bridge:allocation-read", writeName = "$value-array:bridge:allocation-write",
			acceptsName = "$value-array:bridge:allocation-accepts";
		for (shape in [{stride: 32, refs: 0, bits: 32, validity: true}, {stride: 64, refs: 1, bits: 64, validity: true},
				{stride: 0, refs: 1, bits: 32, validity: false}]) {
			var array = allocationBuilder.call("$value-array:test-allocate", [allocationBuilder.constInt(2), allocationBuilder.typeValue(Obj("Mixed")),
				allocationBuilder.constInt(shape.stride), allocationBuilder.constInt(shape.refs), allocationBuilder.constInt(shape.bits),
				allocationBuilder.constBool(shape.validity)], allocationType);
			allocationBuilder.call("$value-array:test-bridge", [array, allocationBuilder.staticClosure(readName, readClosureType),
				allocationBuilder.staticClosure(writeName, writeClosureType), allocationBuilder.staticClosure(acceptsName, acceptsClosureType)], Void);
			arrays.push(array);
		}
		var retyped = allocationBuilder.call("$value-array:test-retype", [arrays[1], allocationBuilder.typeValue(Obj("Mixed")),
			allocationBuilder.constInt(64), allocationBuilder.constInt(1), allocationBuilder.constInt(64), allocationBuilder.constBool(true),
			allocationBuilder.staticClosure(readName, readClosureType), allocationBuilder.staticClosure(writeName, writeClosureType),
			allocationBuilder.staticClosure(acceptsName, acceptsClosureType)], allocationType);
		var laneOwner = allocationBuilder.newObject("AllocationOwner"), laneCarrier = allocationBuilder.call(IrValueLaneReference.PACK, [laneOwner], IrValueLaneReference.type());
		for (index in [1, 2]) allocationBuilder.call("__value_array_write_ref", [arrays[index], allocationBuilder.constInt(1),
			allocationBuilder.constInt(0), laneCarrier], Void);
		allocationBuilder.call("__value_array_mark", [arrays[1], allocationBuilder.constInt(1)], Void);
		for (array in arrays) allocationBuilder.call("__value_array_ensure", [array, allocationBuilder.constInt(9)], Void);
		var mixedCarrier = allocationBuilder.call("__value_array_read_ref", [arrays[1], allocationBuilder.constInt(1), allocationBuilder.constInt(0)], IrValueLaneReference.type()),
			referenceCarrier = allocationBuilder.call("__value_array_read_ref", [arrays[2], allocationBuilder.constInt(1), allocationBuilder.constInt(0)], IrValueLaneReference.type()),
			mixedOwner = allocationBuilder.call(IrValueLaneReference.UNPACK, [mixedCarrier], Obj("AllocationOwner")),
			referenceOwner = allocationBuilder.call(IrValueLaneReference.UNPACK, [referenceCarrier], Obj("AllocationOwner"));
		allocationBuilder.call("__value_array_resize", [arrays[2], allocationBuilder.constInt(1)], Void);
		allocationBuilder.call("__value_array_resize", [arrays[2], allocationBuilder.constInt(10)], Void);
		var resizedCarrier = allocationBuilder.call("__value_array_read_ref", [arrays[2], allocationBuilder.constInt(1), allocationBuilder.constInt(0)], IrValueLaneReference.type()),
			resizedOwner = allocationBuilder.call(IrValueLaneReference.UNPACK, [resizedCarrier], Obj("AllocationOwner"));
		allocationBuilder.call("__value_array_clear", [arrays[1], allocationBuilder.constInt(1)], Void);
		allocationBuilder.call("__value_array_mark", [arrays[1], allocationBuilder.constInt(1)], Void);
		var clearedCarrier = allocationBuilder.call("__value_array_read_ref", [arrays[1], allocationBuilder.constInt(1), allocationBuilder.constInt(0)], IrValueLaneReference.type()),
			clearedOwner = allocationBuilder.call(IrValueLaneReference.UNPACK, [clearedCarrier], Obj("AllocationOwner"));
		var lengths:Array<compiler.ir.Ir.IrValue> = [];
		for (index in 0...arrays.length) {
			var length = new compiler.ir.Ir.IrValue(900000 + index, "$length", I32);
			allocationBuilder.currentBlock().instructions.push(new compiler.ir.SourceProvenance.Located(ArraySize(length, arrays[index]),
				compiler.ir.SourceProvenance.generated("wasm-value-array-allocation-test")));
			lengths.push(length);
		}
		var identityCheck = allocationBuilder.createBlock(), mixedCheck = allocationBuilder.createBlock(), referenceCheck = allocationBuilder.createBlock(), clearedCheck = allocationBuilder.createBlock(),
			allocationSuccess = allocationBuilder.createBlock(), allocationFailure = allocationBuilder.createBlock();
		allocationBuilder.branch(allocationBuilder.equal(retyped, arrays[1]), identityCheck, allocationFailure);
		allocationBuilder.select(identityCheck);
		allocationBuilder.branch(allocationBuilder.equal(mixedOwner, laneOwner), mixedCheck, allocationFailure);
		allocationBuilder.select(mixedCheck); allocationBuilder.branch(allocationBuilder.equal(referenceOwner, laneOwner), referenceCheck, allocationFailure);
		allocationBuilder.select(referenceCheck); allocationBuilder.branch(allocationBuilder.equal(clearedOwner, allocationBuilder.constNull(Obj("AllocationOwner"))), clearedCheck, allocationFailure);
		allocationBuilder.select(clearedCheck); allocationBuilder.branch(allocationBuilder.equal(resizedOwner, allocationBuilder.constNull(Obj("AllocationOwner"))), allocationSuccess, allocationFailure);
		allocationBuilder.select(allocationSuccess); allocationBuilder.returnValue(allocationBuilder.add(allocationBuilder.add(lengths[0], lengths[1]), lengths[2]));
		allocationBuilder.select(allocationFailure); allocationBuilder.returnValue(allocationBuilder.constInt(0));
		var bridgeRead = new IrBuilder(); bridgeRead.argument("array", allocationType); bridgeRead.argument("index", I32);
		bridgeRead.returnValue(bridgeRead.constNull(Dyn));
		var bridgeWrite = new IrBuilder(); bridgeWrite.argument("array", allocationType); bridgeWrite.argument("index", I32); bridgeWrite.argument("value", Dyn); bridgeWrite.argument("insert", Bool);
		bridgeWrite.returnValue(bridgeWrite.constVoid());
		var bridgeAccepts = new IrBuilder(); bridgeAccepts.argument("value", Dyn); bridgeAccepts.returnValue(bridgeAccepts.constBool(true));
		var allocationProgram = new IrProgram("main");
		allocationProgram.objects = [objects.get("Mixed"), {name: "AllocationOwner", isValue: false, base: null, interfaces: [], fields: [], methods: []}];
		allocationProgram.functions = [new IrFunction("main", [], I32, allocationBuilder.blocks),
			new IrFunction(readName, bridgeRead.arguments, Dyn, bridgeRead.blocks), new IrFunction(writeName, bridgeWrite.arguments, Void, bridgeWrite.blocks),
			new IrFunction(acceptsName, bridgeAccepts.arguments, Bool, bridgeAccepts.blocks)];
		allocationProgram.natives = [{name: "$value-array:test-allocate", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: allocationType},
			{name: "$value-array:test-retype", library: "haxeon_runtime", symbol: "__value_array_retype",
				arguments: [allocationType,TypeRef,I32,I32,I32,Bool,readClosureType,writeClosureType,acceptsClosureType], result:allocationType},
			{name: "$value-array:test-bridge", library: "haxeon_runtime", symbol: "__value_array_set_bridge",
				arguments: [allocationType, readClosureType, writeClosureType, acceptsClosureType], result: Void},
			{name: "__value_array_read_ref", library: "haxeon_runtime", symbol: "__value_array_read_ref",
				arguments: [Array(Dyn), I32, I32], result: IrValueLaneReference.type()},
			{name: "__value_array_write_ref", library: "haxeon_runtime", symbol: "__value_array_write_ref",
				arguments: [Array(Dyn), I32, I32, IrValueLaneReference.type()], result: Void},
			{name: "__value_array_clear_ref", library: "haxeon_runtime", symbol: "__value_array_clear_ref", arguments: [Array(Dyn), I32, I32], result: Void}];
		allocationProgram.natives.push({name:"__value_array_mark", library:"haxeon_runtime", symbol:"__value_array_mark", arguments:[Array(Dyn),I32], result:Void});
		allocationProgram.natives.push({name:"__value_array_is_initialized", library:"haxeon_runtime", symbol:"__value_array_is_initialized", arguments:[Array(Dyn),I32], result:Bool});
		allocationProgram.natives.push({name:"__value_array_clear", library:"haxeon_runtime", symbol:"__value_array_clear", arguments:[Array(Dyn),I32], result:Void});
		allocationProgram.natives.push({name:"__value_array_ensure", library:"haxeon_runtime", symbol:"__value_array_ensure", arguments:[Array(Dyn),I32], result:Void});
		allocationProgram.natives.push({name:"__value_array_resize", library:"haxeon_runtime", symbol:"__value_array_resize", arguments:[Array(Dyn),I32], result:Void});
		allocationProgram.natives.push({name:"__value_array_insert_empty", library:"haxeon_runtime", symbol:"__value_array_insert_empty", arguments:[Array(Dyn),I32], result:I32});
		allocationProgram.natives.push({name:"__value_array_reverse", library:"haxeon_runtime", symbol:"__value_array_reverse", arguments:[Array(Dyn)], result:Void});
		allocationProgram.natives.push({name:"__value_array_copy", library:"haxeon_runtime", symbol:"__value_array_copy", arguments:[Array(Dyn)], result:allocationType});
		allocationProgram.natives.push({name:"__value_array_slice", library:"haxeon_runtime", symbol:"__value_array_slice", arguments:[Array(Dyn),I32,I32], result:allocationType});
		allocationProgram.natives.push({name:"__value_array_concat", library:"haxeon_runtime", symbol:"__value_array_concat", arguments:[Array(Dyn),Array(Dyn)], result:allocationType});
		allocationProgram.natives.push({name:"__value_array_splice", library:"haxeon_runtime", symbol:"__value_array_splice", arguments:[Array(Dyn),I32,I32], result:allocationType});
		var allocationBytes = new compiler.backend.wasm.WasmBackend().compile(allocationProgram,
			{target: WasmGc, debugNames: true, wasmGcAllocationCount: true}).bytes;
		var forwardBuilder = new IrBuilder();
		var originalArray = forwardBuilder.call("__array_alloc_ref", [forwardBuilder.constInt(1)], Array(Dyn));
		var forwarded = forwardBuilder.call("$value-array:test-forward", [originalArray, forwardBuilder.typeValue(Obj("Mixed")),
			forwardBuilder.constInt(64), forwardBuilder.constInt(1), forwardBuilder.constInt(64), forwardBuilder.constBool(true),
			forwardBuilder.staticClosure(readName, readClosureType), forwardBuilder.staticClosure(writeName, writeClosureType),
			forwardBuilder.staticClosure(acceptsName, acceptsClosureType)], allocationType);
		forwardBuilder.call("__value_array_ensure", [forwarded, forwardBuilder.constInt(9)], Void);
		var forwardOwner = forwardBuilder.newObject("AllocationOwner"), forwardCarrier = forwardBuilder.call(IrValueLaneReference.PACK, [forwardOwner], IrValueLaneReference.type());
		forwardBuilder.call("__value_array_write_ref", [originalArray, forwardBuilder.constInt(9), forwardBuilder.constInt(0), forwardCarrier], Void);
		forwardBuilder.call("__value_array_mark", [forwarded, forwardBuilder.constInt(9)], Void);
		var forwardedCarrier = forwardBuilder.call("__value_array_read_ref", [forwarded, forwardBuilder.constInt(9), forwardBuilder.constInt(0)], IrValueLaneReference.type());
		var forwardedOwner = forwardBuilder.call(IrValueLaneReference.UNPACK, [forwardedCarrier], Obj("AllocationOwner"));
		var forwardLength = new compiler.ir.Ir.IrValue(800000, "$forward-length", I32);
		forwardBuilder.currentBlock().instructions.push(new compiler.ir.SourceProvenance.Located(ArraySize(forwardLength, originalArray),
			compiler.ir.SourceProvenance.generated("wasm-value-array-forward-test")));
		var forwardCheck = forwardBuilder.createBlock(), forwardOwnerCheck = forwardBuilder.createBlock(), forwardSuccess = forwardBuilder.createBlock(), forwardFailure = forwardBuilder.createBlock();
		forwardBuilder.branch(forwardBuilder.equal(forwardBuilder.toDyn(originalArray), forwardBuilder.toDyn(forwarded)), forwardCheck, forwardFailure);
		forwardBuilder.select(forwardCheck); forwardBuilder.branch(forwardBuilder.equal(forwardLength, forwardBuilder.constInt(10)), forwardOwnerCheck, forwardFailure);
		forwardBuilder.select(forwardOwnerCheck); forwardBuilder.branch(forwardBuilder.equal(forwardedOwner, forwardOwner), forwardSuccess, forwardFailure);
		forwardBuilder.select(forwardSuccess); forwardBuilder.returnValue(forwardBuilder.constInt(1));
		forwardBuilder.select(forwardFailure); forwardBuilder.returnValue(forwardBuilder.constInt(0));
		var forwardProgram = new IrProgram("main"); forwardProgram.objects = allocationProgram.objects;
		forwardProgram.functions = [new IrFunction("main", [], I32, forwardBuilder.blocks), new IrFunction(readName, bridgeRead.arguments, Dyn, bridgeRead.blocks),
			new IrFunction(writeName, bridgeWrite.arguments, Void, bridgeWrite.blocks), new IrFunction(acceptsName, bridgeAccepts.arguments, Bool, bridgeAccepts.blocks)];
		forwardProgram.natives = allocationProgram.natives.concat([
			{name:"__array_alloc_ref", library:"haxeon_runtime", symbol:"__array_alloc_ref", arguments:[I32], result:Array(Dyn)},
			{name:"$value-array:test-forward", library:"haxeon_runtime", symbol:"__value_array_retype", arguments:[Array(Dyn),TypeRef,I32,I32,I32,Bool,readClosureType,writeClosureType,acceptsClosureType], result:allocationType}]);
		var forwardBytes = new compiler.backend.wasm.WasmBackend().compile(forwardProgram, {target:WasmGc, debugNames:true}).bytes;
		var lazyBuilder = new IrBuilder();
		var lazyArray = lazyBuilder.call("$value-array:test-allocate", [lazyBuilder.constInt(1), lazyBuilder.typeValue(Obj("Mixed")),
			lazyBuilder.constInt(64), lazyBuilder.constInt(1), lazyBuilder.constInt(64), lazyBuilder.constBool(true)], allocationType);
		var nullOwner = lazyBuilder.constNull(Obj("AllocationOwner"));
		var nullCarrier = lazyBuilder.call(IrValueLaneReference.PACK, [nullOwner], IrValueLaneReference.type());
		lazyBuilder.call("__value_array_write_ref", [lazyArray, lazyBuilder.constInt(0), lazyBuilder.constInt(0), nullCarrier], Void);
		lazyBuilder.call("__value_array_clear_ref", [lazyArray, lazyBuilder.constInt(0), lazyBuilder.constInt(0)], Void);
		lazyBuilder.call("__value_array_ensure", [lazyArray, lazyBuilder.constInt(9)], Void);
		lazyBuilder.call("__value_array_mark", [lazyArray, lazyBuilder.constInt(0)], Void);
		lazyBuilder.call("__value_array_reverse", [lazyArray], Void);
		var lazyCarrier = lazyBuilder.call("__value_array_read_ref", [lazyArray, lazyBuilder.constInt(9), lazyBuilder.constInt(0)], IrValueLaneReference.type());
		var lazyOwner = lazyBuilder.call(IrValueLaneReference.UNPACK, [lazyCarrier], Obj("AllocationOwner"));
		var lazySuccess = lazyBuilder.createBlock(), lazyFailure = lazyBuilder.createBlock();
		lazyBuilder.branch(lazyBuilder.equal(lazyOwner, nullOwner), lazySuccess, lazyFailure);
		lazyBuilder.select(lazySuccess); lazyBuilder.returnValue(lazyBuilder.constInt(1));
		lazyBuilder.select(lazyFailure); lazyBuilder.returnValue(lazyBuilder.constInt(0));
		var lazyProgram = new IrProgram("main");
		lazyProgram.objects = allocationProgram.objects;
		lazyProgram.functions = [new IrFunction("main", [], I32, lazyBuilder.blocks)];
		lazyProgram.natives = allocationProgram.natives;
		var lazyBytes = new compiler.backend.wasm.WasmBackend().compile(lazyProgram,
			{target: WasmGc, debugNames: true, wasmGcAllocationCount: true}).bytes;
		var scalarBuilder = new IrBuilder(), scalarChecks:Array<compiler.ir.Ir.IrValue> = [];
		for (wordBits in [32, 64]) {
			var mixedInsert = scalarBuilder.call("$value-array:test-allocate", [scalarBuilder.constInt(2), scalarBuilder.typeValue(Obj("Mixed")),
				scalarBuilder.constInt(24), scalarBuilder.constInt(1), scalarBuilder.constInt(wordBits), scalarBuilder.constBool(true)], allocationType);
			var insertOwner = scalarBuilder.newObject("AllocationOwner"), insertCarrier = scalarBuilder.call(IrValueLaneReference.PACK, [insertOwner], IrValueLaneReference.type());
			scalarBuilder.call("__value_array_write_ref", [mixedInsert, scalarBuilder.constInt(1), scalarBuilder.constInt(0), insertCarrier], Void);
			scalarBuilder.call("__value_array_mark", [mixedInsert, scalarBuilder.constInt(1)], Void);
			var insertedFront = scalarBuilder.call("__value_array_insert_empty", [mixedInsert, scalarBuilder.constInt(-10)], I32);
			scalarChecks.push(scalarBuilder.equal(insertedFront, scalarBuilder.constInt(0)));
			var movedCarrier = scalarBuilder.call("__value_array_read_ref", [mixedInsert, scalarBuilder.constInt(2), scalarBuilder.constInt(0)], IrValueLaneReference.type());
			var movedOwner = scalarBuilder.call(IrValueLaneReference.UNPACK, [movedCarrier], Obj("AllocationOwner"));
			scalarChecks.push(scalarBuilder.equal(movedOwner, insertOwner));
			var insertedEnd = scalarBuilder.call("__value_array_insert_empty", [mixedInsert, scalarBuilder.constInt(100)], I32);
			scalarChecks.push(scalarBuilder.equal(insertedEnd, scalarBuilder.constInt(3)));
			scalarBuilder.call("__value_array_reverse", [mixedInsert], Void);
			var reversedCarrier = scalarBuilder.call("__value_array_read_ref", [mixedInsert, scalarBuilder.constInt(1), scalarBuilder.constInt(0)], IrValueLaneReference.type());
			var reversedOwner = scalarBuilder.call(IrValueLaneReference.UNPACK, [reversedCarrier], Obj("AllocationOwner"));
			scalarChecks.push(scalarBuilder.equal(reversedOwner, insertOwner));
			var reversedEmpty = scalarBuilder.call("__value_array_is_initialized", [mixedInsert, scalarBuilder.constInt(2)], Bool);
			scalarChecks.push(scalarBuilder.equal(reversedEmpty, scalarBuilder.constBool(false)));
			var mixedCopy = scalarBuilder.call("__value_array_copy", [mixedInsert], allocationType);
			scalarBuilder.call("__value_array_clear", [mixedInsert, scalarBuilder.constInt(1)], Void);
			var copyCarrier = scalarBuilder.call("__value_array_read_ref", [mixedCopy, scalarBuilder.constInt(1), scalarBuilder.constInt(0)], IrValueLaneReference.type());
			var copyOwner = scalarBuilder.call(IrValueLaneReference.UNPACK, [copyCarrier], Obj("AllocationOwner"));
			scalarChecks.push(scalarBuilder.equal(copyOwner, insertOwner));
			var concatenatedMixed = scalarBuilder.call("__value_array_concat", [mixedCopy, mixedCopy], allocationType);
			var concatCarrier = scalarBuilder.call("__value_array_read_ref", [concatenatedMixed, scalarBuilder.constInt(5), scalarBuilder.constInt(0)], IrValueLaneReference.type());
			var concatOwner = scalarBuilder.call(IrValueLaneReference.UNPACK, [concatCarrier], Obj("AllocationOwner"));
			scalarChecks.push(scalarBuilder.equal(concatOwner, insertOwner));
			var removedMixed = scalarBuilder.call("__value_array_splice", [concatenatedMixed, scalarBuilder.constInt(0), scalarBuilder.constInt(4)], allocationType);
			for (array in [removedMixed, concatenatedMixed]) {
				var keptCarrier = scalarBuilder.call("__value_array_read_ref", [array, scalarBuilder.constInt(1), scalarBuilder.constInt(0)], IrValueLaneReference.type());
				var keptOwner = scalarBuilder.call(IrValueLaneReference.UNPACK, [keptCarrier], Obj("AllocationOwner"));
				scalarChecks.push(scalarBuilder.equal(keptOwner, insertOwner));
			}
			var empty = scalarBuilder.call("$value-array:test-allocate", [scalarBuilder.constInt(0), scalarBuilder.typeValue(Obj("Mixed")),
				scalarBuilder.constInt(0), scalarBuilder.constInt(0), scalarBuilder.constInt(wordBits), scalarBuilder.constBool(false)], allocationType);
			scalarBuilder.call("__value_array_ensure", [empty, scalarBuilder.constInt(9)], Void);
			var optional = scalarBuilder.call("$value-array:test-allocate", [scalarBuilder.constInt(70), scalarBuilder.typeValue(Obj("Mixed")),
				scalarBuilder.constInt(24), scalarBuilder.constInt(0), scalarBuilder.constInt(wordBits), scalarBuilder.constBool(true)], allocationType);
			var absent = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(63)], Bool);
			scalarChecks.push(scalarBuilder.equal(absent, scalarBuilder.constBool(false)));
			scalarBuilder.call("__value_array_mark", [optional, scalarBuilder.constInt(64)], Void);
			var present = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(64)], Bool);
			scalarChecks.push(scalarBuilder.equal(present, scalarBuilder.constBool(true)));
			var stillAbsent = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(63)], Bool);
			scalarChecks.push(scalarBuilder.equal(stillAbsent, scalarBuilder.constBool(false)));
			scalarBuilder.call("__value_array_write_i32", [optional, scalarBuilder.constInt(64), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constInt(1234)], Void);
			scalarBuilder.call("__value_array_write_i32", [optional, scalarBuilder.constInt(65), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constInt(5678)], Void);
			scalarBuilder.call("__value_array_mark", [optional, scalarBuilder.constInt(65)], Void);
			scalarBuilder.call("__value_array_ensure", [optional, scalarBuilder.constInt(100)], Void);
			scalarBuilder.call("__value_array_clear", [optional, scalarBuilder.constInt(64)], Void);
			var clearedPresence = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(64)], Bool);
			scalarChecks.push(scalarBuilder.equal(clearedPresence, scalarBuilder.constBool(false)));
			var neighbor = scalarBuilder.call("__value_array_read_i32", [optional, scalarBuilder.constInt(65), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(neighbor, scalarBuilder.constInt(5678)));
			scalarBuilder.call("__value_array_mark", [optional, scalarBuilder.constInt(64)], Void);
			var clearedValue = scalarBuilder.call("__value_array_read_i32", [optional, scalarBuilder.constInt(64), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(clearedValue, scalarBuilder.constInt(0)));
			scalarBuilder.call("__value_array_resize", [optional, scalarBuilder.constInt(65)], Void);
			scalarBuilder.call("__value_array_resize", [optional, scalarBuilder.constInt(70)], Void);
			var resizedAbsent = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(65)], Bool);
			scalarChecks.push(scalarBuilder.equal(resizedAbsent, scalarBuilder.constBool(false)));
			scalarBuilder.call("__value_array_mark", [optional, scalarBuilder.constInt(65)], Void);
			var resizedValue = scalarBuilder.call("__value_array_read_i32", [optional, scalarBuilder.constInt(65), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(resizedValue, scalarBuilder.constInt(0)));
			scalarBuilder.call("__value_array_write_i32", [optional, scalarBuilder.constInt(64), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constInt(44)], Void);
			scalarBuilder.call("__value_array_clear", [optional, scalarBuilder.constInt(65)], Void);
			scalarBuilder.call("__value_array_write_i32", [optional, scalarBuilder.constInt(66), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constInt(77)], Void);
			scalarBuilder.call("__value_array_mark", [optional, scalarBuilder.constInt(66)], Void);
			var inserted = scalarBuilder.call("__value_array_insert_empty", [optional, scalarBuilder.constInt(64)], I32);
			scalarChecks.push(scalarBuilder.equal(inserted, scalarBuilder.constInt(64)));
			for (index in [64, 66]) {
				var emptyAfterInsert = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(index)], Bool);
				scalarChecks.push(scalarBuilder.equal(emptyAfterInsert, scalarBuilder.constBool(false)));
			}
			for (entry in [{index:65, value:44}, {index:67, value:77}]) {
				var moved = scalarBuilder.call("__value_array_read_i32", [optional, scalarBuilder.constInt(entry.index), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
				scalarChecks.push(scalarBuilder.equal(moved, scalarBuilder.constInt(entry.value)));
			}
			scalarBuilder.call("__value_array_reverse", [optional], Void);
			for (entry in [{index:5, value:44}, {index:3, value:77}]) {
				var reversed = scalarBuilder.call("__value_array_read_i32", [optional, scalarBuilder.constInt(entry.index), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
				scalarChecks.push(scalarBuilder.equal(reversed, scalarBuilder.constInt(entry.value)));
			}
			var reversedAbsent = scalarBuilder.call("__value_array_is_initialized", [optional, scalarBuilder.constInt(4)], Bool);
			scalarChecks.push(scalarBuilder.equal(reversedAbsent, scalarBuilder.constBool(false)));
			var slice = scalarBuilder.call("__value_array_slice", [optional, scalarBuilder.constInt(-68), scalarBuilder.constInt(-64)], allocationType);
			for (entry in [{index:0, value:77}, {index:2, value:44}]) {
				var sliced = scalarBuilder.call("__value_array_read_i32", [slice, scalarBuilder.constInt(entry.index), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
				scalarChecks.push(scalarBuilder.equal(sliced, scalarBuilder.constInt(entry.value)));
			}
			var sliceEmpty = scalarBuilder.call("__value_array_is_initialized", [slice, scalarBuilder.constInt(1)], Bool);
			scalarChecks.push(scalarBuilder.equal(sliceEmpty, scalarBuilder.constBool(false)));
			var concatenated = scalarBuilder.call("__value_array_concat", [slice, slice], allocationType);
			var concatValue = scalarBuilder.call("__value_array_read_i32", [concatenated, scalarBuilder.constInt(6), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(concatValue, scalarBuilder.constInt(44)));
			var concatEmpty = scalarBuilder.call("__value_array_is_initialized", [concatenated, scalarBuilder.constInt(5)], Bool);
			scalarChecks.push(scalarBuilder.equal(concatEmpty, scalarBuilder.constBool(false)));
			var removed = scalarBuilder.call("__value_array_splice", [concatenated, scalarBuilder.constInt(1), scalarBuilder.constInt(4)], allocationType);
			for (entry in [{array:removed, index:1, value:44}, {array:removed, index:3, value:77}, {array:concatenated, index:2, value:44}]) {
				var kept = scalarBuilder.call("__value_array_read_i32", [entry.array, scalarBuilder.constInt(entry.index), scalarBuilder.constInt(0), scalarBuilder.constInt(16), scalarBuilder.constBool(false)], I32);
				scalarChecks.push(scalarBuilder.equal(kept, scalarBuilder.constInt(entry.value)));
			}
			var a = scalarBuilder.call("$value-array:test-allocate", [scalarBuilder.constInt(2), scalarBuilder.typeValue(Obj("Mixed")),
				scalarBuilder.constInt(96), scalarBuilder.constInt(0), scalarBuilder.constInt(wordBits), scalarBuilder.constBool(false)], allocationType);
			var zero = scalarBuilder.constInt(0);
			scalarBuilder.call("__value_array_write_i32", [a, zero, scalarBuilder.constInt(0), scalarBuilder.constInt(8), scalarBuilder.constInt(-5)], Void);
			scalarBuilder.call("__value_array_write_i32", [a, zero, scalarBuilder.constInt(16), scalarBuilder.constInt(8), scalarBuilder.constInt(93)], Void);
			scalarBuilder.call("__value_array_write_i32", [a, zero, scalarBuilder.constInt(24), scalarBuilder.constInt(32), scalarBuilder.constInt(0x12345678)], Void);
			scalarBuilder.call("__value_array_write_i64", [a, scalarBuilder.constInt(1), scalarBuilder.constInt(24), scalarBuilder.constInt(64), scalarBuilder.constInt(-1234567, I64)], Void);
			for (check in [{offset:0, width:8, sign:true, value:-5}, {offset:16, width:8, sign:false, value:93},
					{offset:24, width:32, sign:false, value:0x12345678}]) {
				var actual = scalarBuilder.call("__value_array_read_i32", [a, zero, scalarBuilder.constInt(check.offset), scalarBuilder.constInt(check.width), scalarBuilder.constBool(check.sign)], I32);
				scalarChecks.push(scalarBuilder.equal(actual, scalarBuilder.constInt(check.value)));
			}
			var wide = scalarBuilder.call("__value_array_read_i64", [a, scalarBuilder.constInt(1), scalarBuilder.constInt(24), scalarBuilder.constInt(64), scalarBuilder.constBool(true)], I64);
			scalarChecks.push(scalarBuilder.equal(wide, scalarBuilder.constInt(-1234567, I64)));
			scalarBuilder.call("__value_array_clear_scalar", [a, zero, scalarBuilder.constInt(16), scalarBuilder.constInt(8)], Void);
			var cleared = scalarBuilder.call("__value_array_read_i32", [a, zero, scalarBuilder.constInt(16), scalarBuilder.constInt(8), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(cleared, zero));
			var retained = scalarBuilder.call("__value_array_read_i32", [a, zero, scalarBuilder.constInt(24), scalarBuilder.constInt(32), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(retained, scalarBuilder.constInt(0x12345678)));
			scalarBuilder.call("__value_array_write_bool", [a, zero, scalarBuilder.constInt(8), scalarBuilder.constBool(true)], Void);
			var truth = scalarBuilder.call("__value_array_read_bool", [a, zero, scalarBuilder.constInt(8)], Bool);
			scalarChecks.push(scalarBuilder.equal(truth, scalarBuilder.constBool(true)));
			scalarBuilder.call("__value_array_write_f32", [a, zero, scalarBuilder.constInt(56), scalarBuilder.constFloat(1.5, F32)], Void);
			var narrowFloat = scalarBuilder.call("__value_array_read_f32", [a, zero, scalarBuilder.constInt(56)], F32);
			scalarChecks.push(scalarBuilder.equal(narrowFloat, scalarBuilder.constFloat(1.5, F32)));
			scalarBuilder.call("__value_array_write_f64", [a, scalarBuilder.constInt(1), scalarBuilder.constInt(24), scalarBuilder.constFloat(-2.25)], Void);
			var wideFloat = scalarBuilder.call("__value_array_read_f64", [a, scalarBuilder.constInt(1), scalarBuilder.constInt(24)], F64);
			scalarChecks.push(scalarBuilder.equal(wideFloat, scalarBuilder.constFloat(-2.25)));
			var typeHandle = scalarBuilder.typeValue(Obj("AllocationOwner"));
			scalarBuilder.call("__value_array_write_type", [a, zero, scalarBuilder.constInt(24), scalarBuilder.constInt(32), typeHandle], Void);
			var readType = scalarBuilder.call("__value_array_read_type", [a, zero, scalarBuilder.constInt(24), scalarBuilder.constInt(32)], TypeRef);
			scalarBuilder.call("__value_array_write_type", [a, zero, scalarBuilder.constInt(56), scalarBuilder.constInt(32), readType], Void);
			var originalTypeBits = scalarBuilder.call("__value_array_read_i32", [a, zero, scalarBuilder.constInt(24), scalarBuilder.constInt(32), scalarBuilder.constBool(false)], I32),
				copiedTypeBits = scalarBuilder.call("__value_array_read_i32", [a, zero, scalarBuilder.constInt(56), scalarBuilder.constInt(32), scalarBuilder.constBool(false)], I32);
			scalarChecks.push(scalarBuilder.equal(scalarBuilder.equal(originalTypeBits, zero), scalarBuilder.constBool(false)));
			scalarChecks.push(scalarBuilder.equal(copiedTypeBits, originalTypeBits));
		}
		var scalarFailure = scalarBuilder.createBlock();
		for (check in scalarChecks) { var next = scalarBuilder.createBlock(); scalarBuilder.branch(check, next, scalarFailure); scalarBuilder.select(next); }
		scalarBuilder.returnValue(scalarBuilder.constInt(1));
		scalarBuilder.select(scalarFailure); scalarBuilder.returnValue(scalarBuilder.constInt(0));
		var scalarProgram = new IrProgram("main"); scalarProgram.objects = allocationProgram.objects;
		scalarProgram.functions = [new IrFunction("main", [], I32, scalarBuilder.blocks)];
		scalarProgram.natives = allocationProgram.natives.concat([
			{name:"__value_array_write_i32", library:"haxeon_runtime", symbol:"__value_array_write_i32", arguments:[allocationType,I32,I32,I32,I32], result:Void},
			{name:"__value_array_read_i32", library:"haxeon_runtime", symbol:"__value_array_read_i32", arguments:[allocationType,I32,I32,I32,Bool], result:I32},
			{name:"__value_array_write_i64", library:"haxeon_runtime", symbol:"__value_array_write_i64", arguments:[allocationType,I32,I32,I32,I64], result:Void},
			{name:"__value_array_read_i64", library:"haxeon_runtime", symbol:"__value_array_read_i64", arguments:[allocationType,I32,I32,I32,Bool], result:I64},
			{name:"__value_array_write_bool", library:"haxeon_runtime", symbol:"__value_array_write_bool", arguments:[allocationType,I32,I32,Bool], result:Void},
			{name:"__value_array_read_bool", library:"haxeon_runtime", symbol:"__value_array_read_bool", arguments:[allocationType,I32,I32], result:Bool},
			{name:"__value_array_write_f32", library:"haxeon_runtime", symbol:"__value_array_write_f32", arguments:[allocationType,I32,I32,F32], result:Void},
			{name:"__value_array_read_f32", library:"haxeon_runtime", symbol:"__value_array_read_f32", arguments:[allocationType,I32,I32], result:F32},
			{name:"__value_array_write_f64", library:"haxeon_runtime", symbol:"__value_array_write_f64", arguments:[allocationType,I32,I32,F64], result:Void},
			{name:"__value_array_read_f64", library:"haxeon_runtime", symbol:"__value_array_read_f64", arguments:[allocationType,I32,I32], result:F64},
			{name:"__value_array_write_type", library:"haxeon_runtime", symbol:"__value_array_write_type", arguments:[allocationType,I32,I32,I32,TypeRef], result:Void},
			{name:"__value_array_read_type", library:"haxeon_runtime", symbol:"__value_array_read_type", arguments:[allocationType,I32,I32,I32], result:TypeRef},
			{name:"__value_array_clear_scalar", library:"haxeon_runtime", symbol:"__value_array_clear_scalar", arguments:[allocationType,I32,I32,I32], result:Void}]);
		var scalarBytes = new compiler.backend.wasm.WasmBackend().compile(scalarProgram, {target: WasmGc, debugNames: true}).bytes;
		var invalidBuilder = new IrBuilder();
		var invalidArray = invalidBuilder.call("$value-array:test-allocate", [invalidBuilder.constInt(1), invalidBuilder.typeValue(Obj("Mixed")),
			invalidBuilder.constInt(32), invalidBuilder.constInt(0), invalidBuilder.constInt(32), invalidBuilder.constBool(true)], allocationType);
		var invalidRead = invalidBuilder.call("__value_array_read_i32", [invalidArray, invalidBuilder.constInt(0), invalidBuilder.constInt(0),
			invalidBuilder.constInt(32), invalidBuilder.constBool(true)], I32);
		invalidBuilder.returnValue(invalidRead);
		var invalidProgram = new IrProgram("main"); invalidProgram.objects = scalarProgram.objects; invalidProgram.natives = scalarProgram.natives;
		invalidProgram.functions = [new IrFunction("main", [], I32, invalidBuilder.blocks)];
		var invalidBytes = new compiler.backend.wasm.WasmBackend().compile(invalidProgram, {target: WasmGc, debugNames: true}).bytes;
		var directory = Sys.getEnv("TMPDIR");
		if (directory == null || directory.length == 0) directory = ".";
		var path = directory + "/haxeon-wasm-bridge-" + Std.random(0x7fffffff) + ".wasm";
		try {
			sys.io.File.saveBytes(path, forwardBytes);
			var forwardJs = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m); if(i.exports.main()!==1) process.exit(1);';
			var forwardProcess = new sys.io.Process("node", ["-e", forwardJs, path]),
				forwardError = forwardProcess.stderr.readAll().toString(), forwardStatus = forwardProcess.exitCode();
			forwardProcess.close();
			if (forwardStatus != 0) throw 'Wasm GC forwarding array failed ($forwardStatus): $forwardError';
			sys.io.File.saveBytes(path, invalidBytes);
			var invalidJs = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m), tag=i.exports.__haxeon_exception; '
				+ 'if(!(tag instanceof WebAssembly.Tag)) throw Error("missing Haxe exception tag"); '
				+ 'try { i.exports.main(); process.exit(1); } catch(e) { '
				+ 'if(!(e instanceof WebAssembly.Exception) || !e.is(tag) || e.getArg(tag,0)!==null) throw e; }';
			var invalidProcess = new sys.io.Process("node", ["-e", invalidJs, path]),
				invalidError = invalidProcess.stderr.readAll().toString(), invalidStatus = invalidProcess.exitCode();
			invalidProcess.close();
			if (invalidStatus != 0) throw 'Wasm GC null element read failed ($invalidStatus): $invalidError';
			sys.io.File.saveBytes(path, scalarBytes);
			var scalarJs = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m); if(i.exports.main()!==1) process.exit(1);';
			var scalarProcess = new sys.io.Process("node", ["-e", scalarJs, path]),
				scalarError = scalarProcess.stderr.readAll().toString(), scalarStatus = scalarProcess.exitCode();
			scalarProcess.close();
			if (scalarStatus != 0) throw 'Wasm GC scalar lanes failed ($scalarStatus): $scalarError';
			sys.io.File.saveBytes(path, lazyBytes);
			var lazyJs = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m); if(i.exports.main()!==1 || i.exports.__allocation_count()!==3) process.exit(1);';
			var lazyProcess = new sys.io.Process("node", ["-e", lazyJs, path]),
				lazyError = lazyProcess.stderr.readAll().toString(), lazyStatus = lazyProcess.exitCode();
			lazyProcess.close();
			if (lazyStatus != 0) throw 'Wasm GC lazy reference lane failed ($lazyStatus): $lazyError';
			sys.io.File.saveBytes(path, allocationBytes);
			var allocationJs = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m); if(i.exports.main()!==30 || i.exports.__allocation_count()!==15 '
				+ '|| i.exports.main()!==30 || i.exports.__allocation_count()!==27) process.exit(1);';
			var allocationProcess = new sys.io.Process("node", ["-e", allocationJs, path]),
				allocationError = allocationProcess.stderr.readAll().toString(), allocationStatus = allocationProcess.exitCode();
			allocationProcess.close();
			if (allocationStatus != 0) throw 'Wasm GC value-array allocation failed ($allocationStatus): $allocationError';
			sys.io.File.saveBytes(path, bridgeBytes);
			var js = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
				+ 'const i=new WebAssembly.Instance(m); if(i.exports.main()!==42 || i.exports.main()!==42 || i.exports.__allocation_count()!==1) process.exit(1);';
			var process = new sys.io.Process("node", ["-e", js, path]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw 'Wasm GC bridge closure sharing failed ($status): $error';
		} catch (error:Dynamic) {
			if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		var invalidBuilder = new IrBuilder();
		invalidBuilder.call(IrValueLaneReference.PACK, [invalidBuilder.constInt(1)], IrValueLaneReference.type());
		invalidBuilder.returnValue(invalidBuilder.constInt(0));
		var invalidProgram = new IrProgram("main");
		invalidProgram.functions = [new IrFunction("main", [], I32, invalidBuilder.blocks)];
		var rejected = false;
		try IrVerifier.verify(invalidProgram) catch (_:Dynamic) rejected = true;
		if (!rejected) throw "lane reference casts must reject scalar values";
		Sys.println("PASS: inline value layout preserves nested presence and reference slots");
	}
}
