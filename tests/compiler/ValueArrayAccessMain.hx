import compiler.hl.HlWriter;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueArraySlotHelpers;
import compiler.ir.IrValueArrayPlaceMethods;
import compiler.ir.IrValueArrayBridge;
import compiler.ir.IrValueArrayFactory;
import compiler.ir.IrValueArrayElements;
import compiler.ir.IrScalarReplacement;
import compiler.ir.IrValueLaneLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.IrVerifier;
import compiler.ir.hl.HlLower;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/** Execute compiler-generated lane operations through the production HashLink native ABI. */
class ValueArrayAccessMain {
	static function main():Void {
		var boxedRangeSource = 'struct BoxedPoint { public var x:Int; public function new(x:Int) this.x=x; } '
			+ 'function main():Int { var source:Array<BoxedPoint>=[new BoxedPoint(1),new BoxedPoint(2)]; '
			+ 'var copied=source.copy(); var joined=source.concat(source); source[0].x=9; '
			+ 'return copied[0].x==1 && joined[0].x==1 ? 42 : 0; }';
		if (new compiler.ir.IrInterpreter(compiler.Frontend.compile(boxedRangeSource)).run("main") != 42)
			throw "Portable boxed array copies must retain value semantics";
		var frontendSource = 'struct PlaceLeaf { public var x:Int; public function new(x:Int) this.x = x; public function bump(n:Int):Void x += n; } '
			+ 'struct PlaceRoot { public var leaf:PlaceLeaf; public function new(x:Int) leaf = new PlaceLeaf(x); } '
			+ 'function missingValue(a:Array<PlaceRoot>):Bool { try { var v = a[15].leaf.x; return false; } catch (error:Dynamic) { return true; } } '
			+ 'function main():Int { var a:Array<PlaceRoot> = [new PlaceRoot(1)]; a[0].leaf.x = 4; a[0].leaf.bump(2); '
			+ 'var copy = a[0]; a.push(copy); a[0].leaf.x = 8; for (i in 0...10) a.push(new PlaceRoot(i)); '
			+ 'var popped = a.pop(); var shifted = a.shift(); if (popped.leaf.x != 9 || shifted.leaf.x != 8) return 0; '
			+ 'a.unshift(shifted); a.push(popped); '
			+ 'a.unshift(new PlaceRoot(22)); a.insert(2, new PlaceRoot(33)); a.reverse(); a.reverse(); '
			+ 'var removed = a.splice(2, 1); a.resize(16); var snapshot = a.copy(); a.resize(13); '
			+ 'var missing = missingValue(snapshot); '
			+ 'var slice = a.slice(0, 3); var joined = a.concat(slice); a[0].leaf.x = 70; '
			+ 'var copiesOK = snapshot.length == 16 && snapshot[0].leaf.x == 22 && slice[0].leaf.x == 22 && joined[13].leaf.x == 22; '
			+ 'a[0].leaf.x = 22; '
			+ 'a[2].leaf = a[1].leaf; a[1].leaf.x = 9; var nestedCopy = a[2].leaf.x == 8; a[1].leaf.x = 8; a[2].leaf.x = 6; '
			+ 'var total = 0; for (value in a) total += value.leaf.x; '
			+ 'return a[0].leaf.x == 22 && a[1].leaf.x == 8 && removed[0].leaf.x == 33 && a[2].leaf.x == 6 '
			+ '&& total == 81 && copiesOK && missing && nestedCopy ? copy.leaf.x + a[12].leaf.x : 0; }';
		var frontend = compiler.Frontend.compile(frontendSource);
		var wasmFrontend = compiler.Frontend.compile(frontendSource);
		var nullableSource = 'class OptionalOwner { public function new() {} } '
			+ 'struct OptionalChild { public var x:Int; public var owner:OptionalOwner; '
			+ 'public function new(x:Int, owner:OptionalOwner) { this.x = x; this.owner = owner; } } '
			+ 'struct OptionalParent { public var child:Null<OptionalChild>; public function new() child = null; } '
			+ 'function main():Int { var owner = new OptionalOwner(); var values:Array<OptionalParent> = [new OptionalParent(), new OptionalParent()]; '
			+ 'values[0].child = new OptionalChild(5, owner); values[1].child = values[0].child; var snapshot = values.copy(); '
			+ 'values[0].child = null; values[1].child = null; var saved = snapshot[1].child; '
			+ 'return values[0].child == null && values[1].child == null && saved != null && saved.x == 5 && saved.owner == owner ? 42 : 0; }';
		var nullableFrontend = compiler.Frontend.compile(nullableSource);
		var nullableElementSource = 'class ElementOwner { public function new() {} } '
			+ 'struct OptionalElement { public var x:Int; public var owner:ElementOwner; '
			+ 'public function new(x:Int, owner:ElementOwner) { this.x = x; this.owner = owner; } } '
			+ 'function main():Int { var owner = new ElementOwner(); var values:Array<Null<OptionalElement>> = [new OptionalElement(5, owner), null]; '
			+ 'var saved = values[0]; values[0] = null; if (saved == null) return 0; values[1] = saved; '
			+ 'values.push(null); values.push(saved); values.unshift(null); values.insert(1, saved); '
			+ 'values.reverse(); var reversed = values[0]; values.reverse(); var removed = values.splice(1, 1); values.resize(8); '
			+ 'var grownNull = values[7] == null; values.resize(5); '
			+ 'var snapshot = values.copy(); var slice = values.slice(0, 5); var joined = values.concat(slice); '
			+ 'values[2] = null; values[4] = null; '
			+ 'var restored = snapshot[2]; var sliced = slice[4]; var concatenated = joined[7]; var removedValue = removed[0]; '
			+ 'return values[0] == null && values[1] == null && restored != null && restored.x == 5 && restored.owner == owner '
			+ '&& grownNull && snapshot[0] == null && snapshot[1] == null && snapshot[3] == null '
			+ '&& reversed != null && reversed.x == 5 && reversed.owner == owner '
			+ '&& removedValue != null && removedValue.x == 5 && removedValue.owner == owner '
			+ '&& sliced != null && sliced.x == 5 && sliced.owner == owner && concatenated != null && concatenated.x == 5 '
			+ '&& concatenated.owner == owner ? 42 : 0; }';
		var nullableElementFrontend = compiler.Frontend.compile(nullableElementSource);
		var nullableElementFile = new compiler.Source.SourceFile("<nullable-element-array>", nullableElementSource),
			nullableElementAst = new compiler.syntax.Parser(new compiler.syntax.Lexer(nullableElementFile).tokenize()).parseProgram();
		compiler.ir.IrGenerator.bindNativeArrayChecks(true);
		var nullableElementChecked = compiler.ir.IrGenerator.generate(compiler.types.Typer.type(nullableElementAst));
		compiler.ir.IrGenerator.bindNativeArrayChecks(false);
		var nullableFile = new compiler.Source.SourceFile("<nullable-array>", nullableSource),
			nullableAst = new compiler.syntax.Parser(new compiler.syntax.Lexer(nullableFile).tokenize()).parseProgram();
		compiler.ir.IrGenerator.bindNativeArrayChecks(true);
		var nullableCheckedFrontend = compiler.ir.IrGenerator.generate(compiler.types.Typer.type(nullableAst));
		compiler.ir.IrGenerator.bindNativeArrayChecks(false);
		var typedFile = new compiler.Source.SourceFile("<typed-array>", frontendSource),
			typedAst = new compiler.syntax.Parser(new compiler.syntax.Lexer(typedFile).tokenize()).parseProgram();
		compiler.ir.IrGenerator.bindNativeArrayChecks(true);
		var typedFrontend = compiler.ir.IrGenerator.generate(compiler.types.Typer.type(typedAst));
		compiler.ir.IrGenerator.bindNativeArrayChecks(false);
		var hasTypedAllocation = false;
		for (fn in typedFrontend.functions) if (fn.name == "main") for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, "__array_alloc_typed_ref", _): hasTypedAllocation = true;
			default:
		}
		if (!hasTypedAllocation) throw "Checked frontend did not generate a typed array allocation";
		var frontendMain = [for (fn in frontend.functions) if (fn.name == "main") fn][0],
			frontendRoots = compiler.ir.IrValueArrayPlaceRewrite.roots(frontendMain, Obj("PlaceRoot")), markedRoots = 0, ordinaryReads = 0;
		for (_ in frontendRoots.keys()) markedRoots++;
		for (block in frontendMain.blocks) for (located in block.instructions) switch located.value {
			case ArrayGet(out, array, _) if (Type.enumEq(array.type, Array(Obj("PlaceRoot"))) && !frontendRoots.exists(out.id)): ordinaryReads++;
			default:
		}
		if (markedRoots != 9 || ordinaryReads == 0) throw 'Frontend lost array place or copy distinction: $markedRoots places, $ordinaryReads reads';
		var frontendObjects = IrObjectTable.of([for (object in frontend.objects) object.name => object]);
		var frontendFactory = new IrValueArrayFactory(frontendObjects, Obj("PlaceRoot"), 64, HashLink);
		var frontendMethods = new IrValueArrayPlaceMethods(frontendObjects, Obj("PlaceRoot"), frontendFactory.helpers);
		var loweredFrontendPlace = compiler.ir.IrValueArrayPlaceRewrite.rewrite(frontendMain, Obj("PlaceRoot"), frontendObjects,
			frontendFactory.helpers, frontendMethods, frontendRoots);
		if (loweredFrontendPlace == frontendMain) throw "Frontend array place was not rewritten";
		var element:IrType = Obj("LaneElement"), arrayType:IrType = Array(element);
		var descriptor:IrObject = {
			name: "LaneElement", isValue: true, base: null, interfaces: [], methods: [],
			fields: [
				{name: "tiny", type: I32, scalarStorage: {size: 1, signed: false}},
				{name: "signed", type: I32, scalarStorage: {size: 2, signed: true}},
				{name: "owner", type: Obj("LaneOwner")},
				{name: "type", type: TypeRef},
				{name: "optional", type: Nullable(I32), nullableScalarStorage: {size: 1, signed: false}},
				{name: "inner", type: Obj("LaneInner")},
				{name: "maybe", type: Nullable(Obj("LaneInner"))},
				{name: "inner2", type: Obj("LaneInner")},
				{name: "maybe2", type: Nullable(Obj("LaneInner"))},
				{name: "pair", type: Obj("LanePair")},
				{name: "outer", type: Obj("LaneOuter")}
			]
		};
		var innerDescriptor:IrObject = {name: "LaneInner", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "value", type: I32}, {name: "label", type: Obj("LaneOwner")},
				{name: "flag", type: Nullable(I32), nullableScalarStorage: {size: 1, signed: true}}]};
		var ownerDescriptor:IrObject = {name: "LaneOwner", isValue: false, base: null, interfaces: [], fields: [], methods: []};
		var pairDescriptor:IrObject = {name: "LanePair", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "value", type: I32}, {name: "label", type: Obj("LaneOwner")}]};
		var pairWrapperName = compiler.ir.IrOptionalScalarFlow.wrapperName("LanePair");
		var pairWrapperDescriptor:IrObject = {name: pairWrapperName, isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "$slot0", type: Bool}, {name: "$slot1", type: I32}, {name: "$slot2", type: Obj("LaneOwner")}]};
		var outerDescriptor:IrObject = {name: "LaneOuter", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "nested", type: Obj("LaneInner")}, {name: "maybe", type: Nullable(Obj("LaneInner"))}]};
		var nestedPairDescriptor:IrObject = {name: "LaneNestedPair", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "nested", type: Obj("LanePair")}, {name: "optional", type: Nullable(I32)}]};
		innerDescriptor.methods.push({name: "adjust", functionName: "LaneInner.adjust"});
		var objects:Map<String, IrObject> = ["LaneElement" => descriptor, "LaneInner" => innerDescriptor,
			"LaneOwner" => ownerDescriptor, "LanePair" => pairDescriptor, "LaneOuter" => outerDescriptor, "LaneNestedPair" => nestedPairDescriptor,
			pairWrapperName => pairWrapperDescriptor];
		var shape = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(element);
		var builder = new IrBuilder(), owner = builder.newObject("LaneOwner"), otherOwner = builder.newObject("LaneOwner"), index = builder.constInt(0);
		var array = builder.call("__value_array_alloc", [
			builder.constInt(1), builder.typeValue(element), builder.constInt(shape.scalarStrideBits),
			builder.constInt(shape.references), builder.constInt(shape.scalarWordBits), builder.constBool(true)
		], arrayType);
		var helpers = new IrValueArraySlotHelpers(element, shape);
		var pairType:IrType = Obj("LanePair"), pairArrayType:IrType = Array(pairType);
		var pairFactory = new IrValueArrayFactory(IrObjectTable.of(objects), pairType, 64, HashLink),
			pairHelpers = pairFactory.helpers, pairBridge = pairFactory.bridge;
		var pairElements = new IrValueArrayElements(pairType, pairHelpers, pairBridge);
		var pairBridgeFunctions = pairFactory.functions(), pairElementFunctions = pairElements.functions(), pairHelperFunctions = pairHelpers.functions();
		var optionalPairType:IrType = Nullable(pairType), optionalPairArrayType:IrType = Array(optionalPairType);
		var optionalPairShape = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(optionalPairType);
		var optionalPairHelpers = new IrValueArraySlotHelpers(optionalPairType, optionalPairShape);
		var optionalPairBridge = new IrValueArrayBridge(optionalPairType, IrObjectTable.of(objects), optionalPairHelpers);
		var optionalPairComponents = new compiler.ir.IrValueArrayOptionalComponents(IrObjectTable.of(objects), optionalPairType, optionalPairHelpers);
		var optionalPairBridgeFunctions = optionalPairBridge.functions().concat(optionalPairComponents.functions()),
			optionalPairHelperFunctions = optionalPairHelpers.functions();
		var optionalSnapshotCallbackType:IrType = Function([optionalPairArrayType], Void), optionalSnapshot = new IrBuilder(),
			optionalSnapshotArray = optionalSnapshot.argument("array", optionalPairArrayType),
			optionalSnapshotCallback = optionalSnapshot.argument("callback", optionalSnapshotCallbackType),
			optionalSnapshotIndex = optionalSnapshot.constInt(0), optionalSnapshotRaw = new IrValue(900010, "$optional-snapshot", optionalPairType);
		optionalSnapshot.currentBlock().instructions.push(new Located(ArrayGet(optionalSnapshotRaw, optionalSnapshotArray, optionalSnapshotIndex),
			SourceProvenance.generated("optional-array-snapshot")));
		optionalSnapshot.callClosure(optionalSnapshotCallback, [optionalSnapshotArray], Void);
		var optionalSnapshotParts = optionalSnapshot.call(compiler.ir.IrOptionalValueFlow.unboxName("LanePair"), [optionalSnapshotRaw], Obj(pairWrapperName));
		optionalSnapshot.returnValue(optionalSnapshot.fieldGet(optionalSnapshotParts, "$slot1", I32));
		var rewrittenOptionalSnapshot = compiler.ir.IrValueArrayOptionalRewrite.rewrite(
			new IrFunction("array_optional_snapshot", optionalSnapshot.arguments, I32, optionalSnapshot.blocks), optionalPairType, optionalPairComponents);
		var nestedPairType:IrType = Obj("LaneNestedPair"), nestedPairArrayType:IrType = Array(nestedPairType);
		var nestedPairShape = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(nestedPairType);
		var nestedPairHelpers = new IrValueArraySlotHelpers(nestedPairType, nestedPairShape);
		var nestedPairBridge = new IrValueArrayBridge(nestedPairType, IrObjectTable.of(objects), nestedPairHelpers);
		var nestedPairBridgeFunctions = nestedPairBridge.functions(), nestedPairHelperFunctions = nestedPairHelpers.functions();
		var outerType:IrType = Obj("LaneOuter"), outerArrayType:IrType = Array(outerType);
		var outerShape = new IrValueLaneLayout(IrObjectTable.of(objects), 64, HashLink).shape(outerType);
		var outerHelpers = new IrValueArraySlotHelpers(outerType, outerShape);
		var outerBridge = new IrValueArrayBridge(outerType, IrObjectTable.of(objects), outerHelpers);
		var outerBridgeFunctions = outerBridge.functions(), outerHelperFunctions = outerHelpers.functions();
		var bridgeArray = builder.call(pairFactory.allocateName(), [builder.constInt(1)], pairArrayType);
		var bridgeSource = builder.newObject("LanePair");
		builder.fieldSet(bridgeSource, "value", builder.constInt(314));
		builder.fieldSet(bridgeSource, "label", owner);
		var dynamicPair = builder.toDyn(bridgeSource);
		var bridgeAccepted = builder.call(pairBridge.acceptsName(), [dynamicPair], Bool);
		var bridgeRejected = builder.call(pairBridge.acceptsName(), [builder.toDyn(owner)], Bool);
		var bridgeNullRejected = builder.call(pairBridge.acceptsName(), [builder.constNull(Dyn)], Bool);
		builder.call(pairBridge.writeName(), [bridgeArray, index, dynamicPair], Void);
		builder.fieldSet(bridgeSource, "value", builder.constInt(271));
		var bridgeResult = builder.safeCast(builder.call(pairBridge.readName(), [bridgeArray, index], Dyn), pairType);
		var bridgeValue = builder.fieldGet(bridgeResult, "value", I32), bridgeLabel = builder.fieldGet(bridgeResult, "label", Obj("LaneOwner"));
		var pairAcceptsType:IrType = Function([Dyn], Bool);
		builder.call("__array_set_any", [bridgeArray, index, dynamicPair], Void);
		var escapedPair = builder.safeCast(builder.call("__array_get_any", [bridgeArray, index], Dyn), pairType);
		var escapedPairValue = builder.fieldGet(escapedPair, "value", I32), escapedPairLabel = builder.fieldGet(escapedPair, "label", Obj("LaneOwner"));
		var optionalBridgeArray = builder.call("__value_array_alloc_optional_pair", [builder.constInt(1), builder.typeValue(pairType),
			builder.constInt(optionalPairShape.scalarStrideBits), builder.constInt(optionalPairShape.references),
			builder.constInt(optionalPairShape.scalarWordBits), builder.constBool(false)], optionalPairArrayType);
		var optionalBridgeNullAccepted = builder.call(optionalPairBridge.acceptsName(), [builder.constNull(Dyn)], Bool);
		var optionalBridgeAccepted = builder.call(optionalPairBridge.acceptsName(), [dynamicPair], Bool);
		builder.call(optionalPairBridge.writeName(), [optionalBridgeArray, index, dynamicPair], Void);
		var optionalBridgeResult = builder.safeCast(builder.call(optionalPairBridge.readName(), [optionalBridgeArray, index], Dyn), pairType);
		var optionalBridgeValue = builder.fieldGet(optionalBridgeResult, "value", I32);
		var optionalBridgeLabel = builder.fieldGet(optionalBridgeResult, "label", Obj("LaneOwner"));
		var optionalSnapshotClosure = builder.staticClosure("array_optional_snapshot_callback", optionalSnapshotCallbackType);
		var beforeOptionalSnapshot = builder.call("std.gc_total_allocated", [], F64);
		var optionalSnapshotValue = builder.call(rewrittenOptionalSnapshot.name, [optionalBridgeArray, optionalSnapshotClosure], I32);
		var afterOptionalSnapshot = builder.call("std.gc_total_allocated", [], F64);
		var optionalSnapshotCurrent = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["value"])), [optionalBridgeArray, index], I32);
		builder.call(optionalPairBridge.writeName(), [optionalBridgeArray, index, builder.constNull(Dyn)], Void);
		var optionalBridgeNull = builder.call(optionalPairBridge.readName(), [optionalBridgeArray, index], Dyn);
		var optionalBridgeCleared = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["label"])),
			[optionalBridgeArray, index], Obj("LaneOwner"));
		var optionalPushArray = builder.call("__value_array_alloc_optional_pair", [builder.constInt(1000), builder.typeValue(pairType),
			builder.constInt(optionalPairShape.scalarStrideBits), builder.constInt(optionalPairShape.references),
			builder.constInt(optionalPairShape.scalarWordBits), builder.constBool(false)], optionalPairArrayType);
		builder.call("__value_array_resize", [optionalPushArray, builder.constInt(0)], Void);
		var beforeOptionalPush = builder.call("std.gc_total_allocated", [], F64);
		for (i in 0...20) {
			var components = builder.newObject(pairWrapperName);
			builder.fieldSet(components, "$slot0", builder.constBool(i % 2 == 1));
			builder.fieldSet(components, "$slot1", builder.constInt(i));
			builder.fieldSet(components, "$slot2", owner);
			var value = builder.call(compiler.ir.IrOptionalValueFlow.boxName("LanePair"), [components], optionalPairType);
			builder.call("__array_push_ref", [optionalPushArray, value], I32);
		}
		var absentComponents = builder.newObject(pairWrapperName);
		builder.fieldSet(absentComponents, "$slot0", builder.constBool(false));
		builder.fieldSet(absentComponents, "$slot1", builder.constInt(777));
		builder.fieldSet(absentComponents, "$slot2", owner);
		var absentValue = builder.call(compiler.ir.IrOptionalValueFlow.boxName("LanePair"), [absentComponents], optionalPairType);
		builder.call("__array_unshift_any", [optionalPushArray, absentValue], I32);
		var insertedComponents = builder.newObject(pairWrapperName);
		builder.fieldSet(insertedComponents, "$slot0", builder.constBool(true));
		builder.fieldSet(insertedComponents, "$slot1", builder.constInt(42));
		builder.fieldSet(insertedComponents, "$slot2", otherOwner);
		var insertedValue = builder.call(compiler.ir.IrOptionalValueFlow.boxName("LanePair"), [insertedComponents], optionalPairType);
		builder.call("__array_insert_ref", [optionalPushArray, builder.constInt(1), insertedValue], Void);
		var afterOptionalPush = builder.call("std.gc_total_allocated", [], F64);
		var optionalFrontPresent = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot([], true)), [optionalPushArray, index], Bool);
		var optionalFrontRef = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["label"])), [optionalPushArray, index], Obj("LaneOwner"));
		var optionalInsertedValue = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["value"])), [optionalPushArray, builder.constInt(1)], I32);
		var optionalInsertedRef = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["label"])), [optionalPushArray, builder.constInt(1)], Obj("LaneOwner"));
		var optionalLastValue = builder.call(optionalPairHelpers.getter(optionalPairHelpers.slot(["value"])), [optionalPushArray, builder.constInt(21)], I32);
		var nestedBridgeArray = builder.call("__value_array_alloc_nested_pair", [builder.constInt(1), builder.typeValue(nestedPairType),
			builder.constInt(nestedPairShape.scalarStrideBits), builder.constInt(nestedPairShape.references),
			builder.constInt(nestedPairShape.scalarWordBits), builder.constBool(true)], nestedPairArrayType);
		var nestedBridgeSource = builder.newObject("LaneNestedPair");
		builder.fieldSet(nestedBridgeSource, "nested", bridgeSource);
		builder.fieldSet(nestedBridgeSource, "optional", builder.toDyn(builder.constInt(93), Nullable(I32)));
		var dynamicNested = builder.toDyn(nestedBridgeSource);
		builder.call(nestedPairBridge.writeName(), [nestedBridgeArray, index, dynamicNested], Void);
		var nestedBridgeResult = builder.safeCast(builder.call(nestedPairBridge.readName(), [nestedBridgeArray, index], Dyn), nestedPairType);
		var nestedBridgePair = builder.fieldGet(nestedBridgeResult, "nested", pairType);
		var nestedBridgeValue = builder.fieldGet(nestedBridgePair, "value", I32), nestedBridgeLabel = builder.fieldGet(nestedBridgePair, "label", Obj("LaneOwner"));
		var nestedBridgeOptional = builder.fieldGet(nestedBridgeResult, "optional", Nullable(I32));
		var nestedBridgePayload = builder.safeCast(nestedBridgeOptional, I32);
		builder.fieldSet(nestedBridgeSource, "optional", builder.constNull(Nullable(I32)));
		builder.call(nestedPairBridge.writeName(), [nestedBridgeArray, index, dynamicNested], Void);
		var nestedBridgeNullResult = builder.safeCast(builder.call(nestedPairBridge.readName(), [nestedBridgeArray, index], Dyn), nestedPairType);
		var nestedBridgeNull = builder.fieldGet(nestedBridgeNullResult, "optional", Nullable(I32));
		var outerBridgeArray = builder.call("__value_array_alloc_outer", [builder.constInt(1), builder.typeValue(outerType),
			builder.constInt(outerShape.scalarStrideBits), builder.constInt(outerShape.references),
			builder.constInt(outerShape.scalarWordBits), builder.constBool(true)], outerArrayType);
		var outerSource = builder.newObject("LaneOuter"), outerInner = builder.newObject("LaneInner");
		builder.fieldSet(outerInner, "value", builder.constInt(45));
		builder.fieldSet(outerInner, "label", owner);
		builder.fieldSet(outerInner, "flag", builder.toDyn(builder.constInt(-7), Nullable(I32)));
		builder.fieldSet(outerSource, "nested", outerInner);
		builder.fieldSet(outerSource, "maybe", builder.toDyn(outerInner, Nullable(Obj("LaneInner"))));
		var dynamicOuter = builder.toDyn(outerSource);
		var outerReadType:IrType = Function([outerArrayType, I32], Dyn), outerWriteType:IrType = Function([outerArrayType, I32, Dyn], Void);
		builder.call("__value_array_set_bridge_outer", [outerBridgeArray, builder.staticClosure(outerBridge.readName(), outerReadType),
			builder.staticClosure(outerBridge.writeName(), outerWriteType), builder.staticClosure(outerBridge.acceptsName(), pairAcceptsType)], Void);
		builder.call("__array_set_any", [outerBridgeArray, index, dynamicOuter], Void);
		var outerResult = builder.safeCast(builder.call("__array_get_any", [outerBridgeArray, index], Dyn), outerType);
		var bridgeOuterMaybe = builder.fieldGet(outerResult, "maybe", Nullable(Obj("LaneInner")));
		var outerMaybeValue = builder.safeCast(bridgeOuterMaybe, Obj("LaneInner"));
		var bridgeOuterValue = builder.fieldGet(outerMaybeValue, "value", I32), bridgeOuterOwner = builder.fieldGet(outerMaybeValue, "label", Obj("LaneOwner"));
		var bridgeOuterFlag = builder.safeCast(builder.fieldGet(outerMaybeValue, "flag", Nullable(I32)), I32);
		builder.fieldSet(outerSource, "maybe", builder.constNull(Nullable(Obj("LaneInner"))));
		builder.call("__array_set_any", [outerBridgeArray, index, dynamicOuter], Void);
		var outerNullResult = builder.safeCast(builder.call("__array_get_any", [outerBridgeArray, index], Dyn), outerType);
		var outerNull = builder.fieldGet(outerNullResult, "maybe", Nullable(Obj("LaneInner")));
		var outerCleared = builder.call(outerHelpers.getter(outerHelpers.slot(["maybe", "label"])), [outerBridgeArray, index], Obj("LaneOwner"));
		var dynamicArray = builder.call("__array_alloc_ref", [builder.constInt(1)], Array(Dyn));
		builder.call("__array_set_any", [dynamicArray, index, dynamicPair], Void);
		var retypedArray = builder.call(pairFactory.retypeName(), [dynamicArray], pairArrayType);
		var retypedInitial = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [retypedArray, index], I32);
		builder.fieldSet(bridgeSource, "value", builder.constInt(512));
		builder.call("__array_set_any", [dynamicArray, index, dynamicPair], Void);
		var retypedAfterAliasWrite = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [retypedArray, index], I32);
		builder.call("__array_push_any", [dynamicArray, dynamicPair], I32);
		var retypedSize = new IrValue(999999, "$retyped-size", I32);
		builder.currentBlock().instructions.push(new Located(ArraySize(retypedSize, retypedArray), SourceProvenance.generated("array-factory-test")));
		var beforeTypedElements = builder.call("std.gc_total_allocated", [], F64), typedElementValue:IrValue = null, typedElementLabel:IrValue = null;
		for (_ in 0...10) {
			var pair = builder.newObject("LanePair");
			builder.fieldSet(pair, "value", builder.constInt(753));
			builder.fieldSet(pair, "label", otherOwner);
			builder.currentBlock().instructions.push(new Located(ArraySet(bridgeArray, index, pair), SourceProvenance.generated("array-element-test")));
			var loaded = new IrValue(900000 + _, "$typed-element", pairType);
			builder.currentBlock().instructions.push(new Located(ArrayGet(loaded, bridgeArray, index), SourceProvenance.generated("array-element-test")));
			typedElementValue = builder.fieldGet(loaded, "value", I32);
			typedElementLabel = builder.fieldGet(loaded, "label", Obj("LaneOwner"));
		}
		var afterTypedElements = builder.call("std.gc_total_allocated", [], F64);
		var pushArray = builder.call(pairFactory.allocateName(), [builder.constInt(1000)], pairArrayType);
		builder.call("__value_array_resize", [pushArray, builder.constInt(0)], Void);
		var beforeTypedPush = builder.call("std.gc_total_allocated", [], F64), typedPushLength:IrValue = null;
		for (i in 0...20) {
			var pair = builder.newObject("LanePair");
			builder.fieldSet(pair, "value", builder.constInt(i));
			builder.fieldSet(pair, "label", otherOwner);
			typedPushLength = builder.call("__array_push_ref", [pushArray, pair], I32);
		}
		var afterTypedPush = builder.call("std.gc_total_allocated", [], F64);
		var typedPushValue = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [pushArray, builder.constInt(19)], I32);
		var typedPushLabel = builder.call(pairHelpers.getter(pairHelpers.slot(["label"])), [pushArray, builder.constInt(19)], Obj("LaneOwner"));
		var beforeTypedInsert = builder.call("std.gc_total_allocated", [], F64), selectedPair = new IrValue(900100, "$insert-source", pairType);
		builder.currentBlock().instructions.push(new Located(ArrayGet(selectedPair, pushArray, builder.constInt(1)), SourceProvenance.generated("array-insert-test")));
		builder.call("__array_insert_ref", [pushArray, builder.constInt(5), selectedPair], Void);
		var frontPair = builder.newObject("LanePair");
		builder.fieldSet(frontPair, "value", builder.constInt(31));
		builder.fieldSet(frontPair, "label", owner);
		var typedUnshiftLength = builder.call("__array_unshift_ref", [pushArray, frontPair], I32);
		var afterTypedInsert = builder.call("std.gc_total_allocated", [], F64);
		var typedInsertValue = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [pushArray, builder.constInt(6)], I32);
		var typedInsertLabel = builder.call(pairHelpers.getter(pairHelpers.slot(["label"])), [pushArray, builder.constInt(6)], Obj("LaneOwner"));
		var typedFrontValue = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [pushArray, builder.constInt(0)], I32);
		var typedFrontLabel = builder.call(pairHelpers.getter(pairHelpers.slot(["label"])), [pushArray, builder.constInt(0)], Obj("LaneOwner"));
		var beforeTypedRanges = builder.call("std.gc_total_allocated", [], F64);
		builder.call("__array_reverse_ref", [pushArray], Void);
		builder.call("__array_reverse_ref", [pushArray], Void);
		builder.call("__array_resize_ref", [pushArray, builder.constInt(25)], Void);
		var grownInitialized = builder.call("__value_array_is_initialized", [pushArray, builder.constInt(24)], Bool);
		builder.call("__array_resize_ref", [pushArray, builder.constInt(22)], Void);
		var afterTypedRanges = builder.call("std.gc_total_allocated", [], F64);
		var removedPair = builder.call("__array_splice_ref", [pushArray, builder.constInt(6), builder.constInt(1)], pairArrayType);
		builder.call(pairHelpers.setter(pairHelpers.slot(["value"])), [pushArray, builder.constInt(2), builder.constInt(99)], Void);
		var removedPairValue = builder.call(pairHelpers.getter(pairHelpers.slot(["value"])), [removedPair, index], I32);
		var removedPairLabel = builder.call(pairHelpers.getter(pairHelpers.slot(["label"])), [removedPair, index], Obj("LaneOwner"));
		var checkOptional = helpers.checker(["optional"], true);
		var callbackType:IrType = Function([arrayType], Void), method = new IrBuilder();
		var receiver = method.argument("this", element), callback = method.argument("callback", callbackType),
			callbackArray = method.argument("array", arrayType);
		var initial = method.fieldGet(receiver, "signed", I32);
		method.fieldSet(receiver, "signed", method.add(initial, method.constInt(1)));
		method.callClosure(callback, [callbackArray], Void);
		var later = method.fieldGet(receiver, "signed", I32);
		method.fieldSet(receiver, "signed", method.add(later, method.constInt(2)));
		method.returnValue(method.constVoid());
		var methodRewriter = new IrValueArrayPlaceMethods(IrObjectTable.of(objects), element, helpers);
		var rewrittenMethod = methodRewriter.specialize("array_place_around",
			new IrFunction("LaneElement.around", method.arguments, Void, method.blocks), []);
		var throwingMethod = new IrBuilder(), throwingReceiver = throwingMethod.argument("this", element);
		var previous = throwingMethod.fieldGet(throwingReceiver, "signed", I32);
		throwingMethod.fieldSet(throwingReceiver, "signed", throwingMethod.add(previous, throwingMethod.constInt(3)));
		throwingMethod.terminate(Throw(throwingMethod.toDyn(throwingMethod.constString("changed"))));
		var rewrittenThrow = methodRewriter.specialize("array_place_throw",
			new IrFunction("LaneElement.changeThenThrow", throwingMethod.arguments, Void, throwingMethod.blocks), []);
		var nestedMethod = new IrBuilder(), nestedReceiver = nestedMethod.argument("this", element),
			nestedCallback = nestedMethod.argument("callback", callbackType), nestedArray = nestedMethod.argument("array", arrayType);
		var child = nestedMethod.fieldGet(nestedReceiver, "inner", Obj("LaneInner"));
		var nestedInitial = nestedMethod.fieldGet(child, "value", I32);
		nestedMethod.fieldSet(child, "value", nestedMethod.add(nestedInitial, nestedMethod.constInt(1)));
		nestedMethod.callClosure(nestedCallback, [nestedArray], Void);
		var nestedLater = nestedMethod.fieldGet(child, "value", I32);
		nestedMethod.fieldSet(child, "value", nestedMethod.add(nestedLater, nestedMethod.constInt(2)));
		nestedMethod.returnValue(nestedMethod.constVoid());
		var rewrittenNested = methodRewriter.specialize("array_place_nested",
			new IrFunction("LaneElement.nestedAround", nestedMethod.arguments, Void, nestedMethod.blocks), []);
		var snapshotMethod = new IrBuilder(), snapshotReceiver = snapshotMethod.argument("this", element),
			snapshotCallback = snapshotMethod.argument("callback", callbackType), snapshotArray = snapshotMethod.argument("array", arrayType);
		var snapshotChild = snapshotMethod.fieldGet(snapshotReceiver, "inner", Obj("LaneInner"));
		var snapshot = snapshotMethod.newObject("LaneInner");
		snapshotMethod.fieldSet(snapshot, "value", snapshotMethod.fieldGet(snapshotChild, "value", I32));
		snapshotMethod.fieldSet(snapshot, "label", snapshotMethod.fieldGet(snapshotChild, "label", Obj("LaneOwner")));
		snapshotMethod.callClosure(snapshotCallback, [snapshotArray], Void);
		snapshotMethod.returnValue(snapshotMethod.fieldGet(snapshot, "value", I32));
		var rewrittenSnapshot = methodRewriter.specialize("array_place_snapshot",
			new IrFunction("LaneElement.snapshot", snapshotMethod.arguments, I32, snapshotMethod.blocks), []);
		rewrittenSnapshot = IrScalarReplacement.rewrite(rewrittenSnapshot, IrObjectTable.of(objects), false, true);
		for (block in rewrittenSnapshot.blocks) for (located in block.instructions) switch located.value {
			case NewObject(_, "LaneInner"): throw "A copied array value must stay scalar across a callback";
			default:
		}
		var optionalMethod = new IrBuilder(), optionalReceiver = optionalMethod.argument("this", element);
		var optionalValue = optionalMethod.fieldGet(optionalReceiver, "maybe", Nullable(Obj("LaneInner")));
		var absent = optionalMethod.createBlock(), present = optionalMethod.createBlock();
		optionalMethod.branch(optionalMethod.equal(optionalValue, optionalMethod.constNull(Nullable(Obj("LaneInner")))), absent, present);
		optionalMethod.select(absent); optionalMethod.returnValue(optionalMethod.constInt(0));
		optionalMethod.select(present);
		var unwrapped = optionalMethod.safeCast(optionalValue, Obj("LaneInner"));
		var optionalInitial = optionalMethod.fieldGet(unwrapped, "value", I32);
		optionalMethod.fieldSet(unwrapped, "value", optionalMethod.add(optionalInitial, optionalMethod.constInt(2)));
		optionalMethod.returnValue(optionalMethod.fieldGet(unwrapped, "value", I32));
		var rewrittenOptional = methodRewriter.specialize("array_place_optional",
			new IrFunction("LaneElement.optionalValue", optionalMethod.arguments, I32, optionalMethod.blocks), []);
		var scalarSnapshot = new IrBuilder(), scalarReceiver = scalarSnapshot.argument("this", element),
			scalarCallback = scalarSnapshot.argument("callback", callbackType), scalarArray = scalarSnapshot.argument("array", arrayType);
		var savedScalar = scalarSnapshot.fieldGet(scalarReceiver, "optional", Nullable(I32));
		scalarSnapshot.callClosure(scalarCallback, [scalarArray], Void);
		scalarSnapshot.returnValue(scalarSnapshot.safeCast(savedScalar, I32));
		var rewrittenScalarSnapshot = methodRewriter.specialize("array_place_scalar_snapshot",
			new IrFunction("LaneElement.scalarSnapshot", scalarSnapshot.arguments, I32, scalarSnapshot.blocks), []);
		var scalarWrite = new IrBuilder(), writeReceiver = scalarWrite.argument("this", element);
		scalarWrite.fieldSet(writeReceiver, "optional", scalarWrite.constNull(Nullable(I32)));
		var emptyScalar = scalarWrite.fieldGet(writeReceiver, "optional", Nullable(I32));
		var wasNull = scalarWrite.createBlock(), unexpectedlyPresent = scalarWrite.createBlock();
		scalarWrite.branch(scalarWrite.equal(emptyScalar, scalarWrite.constNull(Nullable(I32))), wasNull, unexpectedlyPresent);
		scalarWrite.select(unexpectedlyPresent); scalarWrite.returnValue(scalarWrite.constInt(0));
		scalarWrite.select(wasNull);
		scalarWrite.fieldSet(writeReceiver, "optional", scalarWrite.toDyn(scalarWrite.constInt(257), Nullable(I32)));
		var assignedScalar = scalarWrite.fieldGet(writeReceiver, "optional", Nullable(I32));
		scalarWrite.returnValue(scalarWrite.safeCast(assignedScalar, I32));
		var rewrittenScalarWrite = methodRewriter.specialize("array_place_scalar_write",
			new IrFunction("LaneElement.scalarWrite", scalarWrite.arguments, I32, scalarWrite.blocks), []);
		var scalarNull = new IrBuilder(), nullReceiver = scalarNull.argument("this", element),
			nullCallback = scalarNull.argument("callback", callbackType), nullArray = scalarNull.argument("array", arrayType);
		var nullSnapshot = scalarNull.fieldGet(nullReceiver, "optional", Nullable(I32));
		scalarNull.callClosure(nullCallback, [nullArray], Void);
		var nullYes = scalarNull.createBlock(), nullNo = scalarNull.createBlock();
		scalarNull.branch(scalarNull.equal(nullSnapshot, scalarNull.constNull(Nullable(I32))), nullYes, nullNo);
		scalarNull.select(nullYes); scalarNull.returnValue(scalarNull.constInt(42));
		scalarNull.select(nullNo); scalarNull.returnValue(scalarNull.constInt(0));
		var rewrittenScalarNull = methodRewriter.specialize("array_place_scalar_null",
			new IrFunction("LaneElement.scalarNull", scalarNull.arguments, I32, scalarNull.blocks), []);
		var phiRead = new IrBuilder(), phiReceiver = phiRead.argument("this", element), choose = phiRead.argument("choose", Bool),
			phiCallback = phiRead.argument("callback", callbackType), phiArray = phiRead.argument("array", arrayType);
		var phiSnapshot = phiRead.fieldGet(phiReceiver, "optional", Nullable(I32));
		var phiYes = phiRead.createBlock(), phiNo = phiRead.createBlock(), phiJoin = phiRead.createBlock();
		phiRead.branch(choose, phiYes, phiNo);
		phiRead.select(phiYes); phiRead.jump(phiJoin);
		phiRead.select(phiNo); var phiNull = phiRead.constNull(Nullable(I32)); phiRead.jump(phiJoin);
		phiRead.select(phiJoin);
		var selected = phiRead.phi(Nullable(I32), [{block: phiYes.id, value: phiSnapshot}, {block: phiNo.id, value: phiNull}]);
		phiRead.callClosure(phiCallback, [phiArray], Void);
		var phiAbsent = phiRead.createBlock(), phiPresent = phiRead.createBlock();
		phiRead.branch(phiRead.equal(selected, phiRead.constNull(Nullable(I32))), phiAbsent, phiPresent);
		phiRead.select(phiAbsent); phiRead.returnValue(phiRead.constInt(0));
		phiRead.select(phiPresent); phiRead.returnValue(phiRead.safeCast(selected, I32));
		var rewrittenPhiRead = methodRewriter.specialize("array_place_phi_read",
			new IrFunction("LaneElement.phiRead", phiRead.arguments, I32, phiRead.blocks), []);
		var phiWrite = new IrBuilder(), phiWriteReceiver = phiWrite.argument("this", element), phiWriteChoose = phiWrite.argument("choose", Bool);
		var writeYes = phiWrite.createBlock(), writeNo = phiWrite.createBlock(), writeJoin = phiWrite.createBlock();
		phiWrite.branch(phiWriteChoose, writeYes, writeNo);
		phiWrite.select(writeYes); var some = phiWrite.toDyn(phiWrite.constInt(257), Nullable(I32)); phiWrite.jump(writeJoin);
		phiWrite.select(writeNo); var none = phiWrite.constNull(Nullable(I32)); phiWrite.jump(writeJoin);
		phiWrite.select(writeJoin);
		var chosen = phiWrite.phi(Nullable(I32), [{block: writeYes.id, value: some}, {block: writeNo.id, value: none}]);
		phiWrite.fieldSet(phiWriteReceiver, "optional", chosen);
		var written = phiWrite.fieldGet(phiWriteReceiver, "optional", Nullable(I32));
		var writtenNull = phiWrite.createBlock(), writtenSome = phiWrite.createBlock();
		phiWrite.branch(phiWrite.equal(written, phiWrite.constNull(Nullable(I32))), writtenNull, writtenSome);
		phiWrite.select(writtenNull); phiWrite.returnValue(phiWrite.constInt(0));
		phiWrite.select(writtenSome); phiWrite.returnValue(phiWrite.safeCast(written, I32));
		var rewrittenPhiWrite = methodRewriter.specialize("array_place_phi_write",
			new IrFunction("LaneElement.phiWrite", phiWrite.arguments, I32, phiWrite.blocks), []);
		var copyMethod = new IrBuilder(), copyReceiver = copyMethod.argument("this", element);
		var copySource = copyMethod.fieldGet(copyReceiver, "inner2", Obj("LaneInner"));
		copyMethod.fieldSet(copyReceiver, "inner", copySource);
		copyMethod.returnValue(copyMethod.constVoid());
		var rewrittenCopy = methodRewriter.specialize("array_place_copy",
			new IrFunction("LaneElement.copyInner", copyMethod.arguments, Void, copyMethod.blocks), []);
		var selfMethod = new IrBuilder(), selfReceiver = selfMethod.argument("this", element);
		var selfSource = selfMethod.fieldGet(selfReceiver, "inner", Obj("LaneInner"));
		selfMethod.fieldSet(selfReceiver, "inner", selfSource);
		selfMethod.returnValue(selfMethod.constVoid());
		var rewrittenSelf = methodRewriter.specialize("array_place_self_copy",
			new IrFunction("LaneElement.copySelf", selfMethod.arguments, Void, selfMethod.blocks), []);
		var optionalCopy = new IrBuilder(), optionalCopyReceiver = optionalCopy.argument("this", element);
		var optionalSource = optionalCopy.fieldGet(optionalCopyReceiver, "maybe2", Nullable(Obj("LaneInner")));
		optionalCopy.fieldSet(optionalCopyReceiver, "maybe", optionalSource);
		optionalCopy.returnValue(optionalCopy.constVoid());
		var rewrittenOptionalCopy = methodRewriter.specialize("array_place_optional_copy",
			new IrFunction("LaneElement.copyOptional", optionalCopy.arguments, Void, optionalCopy.blocks), []);
		var construct = new IrBuilder(), constructReceiver = construct.argument("this", element),
			constructValue = construct.argument("value", I32), constructLabel = construct.argument("label", Obj("LaneOwner"));
		var freshPair = construct.newObject("LanePair");
		construct.fieldSet(freshPair, "value", constructValue);
		construct.fieldSet(freshPair, "label", constructLabel);
		construct.fieldSet(constructReceiver, "pair", freshPair);
		construct.returnValue(construct.constVoid());
		var rewrittenConstruct = methodRewriter.specialize("array_place_construct",
			new IrFunction("LaneElement.constructPair", construct.arguments, Void, construct.blocks), []);
		rewrittenConstruct = IrScalarReplacement.rewrite(rewrittenConstruct, IrObjectTable.of(objects), false, true);
		for (block in rewrittenConstruct.blocks) for (located in block.instructions) switch located.value {
			case NewObject(_, "LanePair"): throw "A constructed array value must stay scalar";
			default:
		}
		var copyArgument = new IrBuilder(), argumentReceiver = copyArgument.argument("this", element),
			pairArgument = copyArgument.argument("pair", Obj("LanePair"));
		copyArgument.fieldSet(argumentReceiver, "pair", pairArgument);
		copyArgument.returnValue(copyArgument.constVoid());
		var rewrittenArgument = methodRewriter.specialize("array_place_copy_argument",
			new IrFunction("LaneElement.copyArgument", copyArgument.arguments, Void, copyArgument.blocks), []);
		var composite = new IrBuilder(), compositeReceiver = composite.argument("this", element),
			compositeCallback = composite.argument("callback", callbackType), compositeArray = composite.argument("array", arrayType);
		var compositeSource = composite.fieldGet(compositeReceiver, "inner2", Obj("LaneInner"));
		var compositeSaved = composite.newObject("LaneInner");
		composite.fieldSet(compositeSaved, "value", composite.fieldGet(compositeSource, "value", I32));
		composite.fieldSet(compositeSaved, "label", composite.fieldGet(compositeSource, "label", Obj("LaneOwner")));
		composite.fieldSet(compositeSaved, "flag", composite.fieldGet(compositeSource, "flag", Nullable(I32)));
		composite.callClosure(compositeCallback, [compositeArray], Void);
		composite.fieldSet(compositeReceiver, "inner", compositeSaved);
		composite.returnValue(composite.constVoid());
		var rewrittenComposite = methodRewriter.specialize("array_place_composite_snapshot",
			new IrFunction("LaneElement.compositeSnapshot", composite.arguments, Void, composite.blocks), []);
		for (block in rewrittenComposite.blocks) for (located in block.instructions) switch located.value {
			case NewObject(_, "LaneInner"): throw "A composite snapshot must stay scalar";
			default:
		}
		var defaults = new IrBuilder(), defaultsReceiver = defaults.argument("this", element);
		var defaultInner = defaults.newObject("LaneInner");
		defaults.fieldSet(defaultsReceiver, "inner", defaultInner);
		defaults.returnValue(defaults.constVoid());
		var rewrittenDefaults = methodRewriter.specialize("array_place_defaults",
			new IrFunction("LaneElement.defaults", defaults.arguments, Void, defaults.blocks), []);
		var nestedDefaults = new IrBuilder(), nestedDefaultsReceiver = nestedDefaults.argument("this", element);
		var defaultOuter = nestedDefaults.newObject("LaneOuter");
		nestedDefaults.fieldSet(nestedDefaultsReceiver, "outer", defaultOuter);
		nestedDefaults.returnValue(nestedDefaults.constVoid());
		var rewrittenNestedDefaults = methodRewriter.specialize("array_place_nested_defaults",
			new IrFunction("LaneElement.nestedDefaults", nestedDefaults.arguments, Void, nestedDefaults.blocks), []);
		var nestedConstruct = new IrBuilder(), nestedConstructReceiver = nestedConstruct.argument("this", element),
			nestedConstructLabel = nestedConstruct.argument("label", Obj("LaneOwner"));
		var constructedOuter = nestedConstruct.newObject("LaneOuter"), constructedInner = nestedConstruct.newObject("LaneInner");
		nestedConstruct.fieldSet(constructedInner, "value", nestedConstruct.constInt(23));
		nestedConstruct.fieldSet(constructedInner, "label", nestedConstructLabel);
		nestedConstruct.fieldSet(constructedInner, "flag", nestedConstruct.toDyn(nestedConstruct.constInt(5), Nullable(I32)));
		nestedConstruct.fieldSet(constructedOuter, "nested", constructedInner);
		var optionalConstructedInner = nestedConstruct.toDyn(constructedInner, Nullable(Obj("LaneInner")));
		nestedConstruct.fieldSet(constructedInner, "value", nestedConstruct.constInt(32));
		nestedConstruct.fieldSet(constructedInner, "label", nestedConstruct.constNull(Obj("LaneOwner")));
		nestedConstruct.fieldSet(constructedInner, "flag", nestedConstruct.constNull(Nullable(I32)));
		nestedConstruct.fieldSet(constructedOuter, "maybe", optionalConstructedInner);
		nestedConstruct.fieldSet(nestedConstructReceiver, "outer", constructedOuter);
		nestedConstruct.returnValue(nestedConstruct.constVoid());
		var rewrittenNestedConstruct = methodRewriter.specialize("array_place_nested_construct",
			new IrFunction("LaneElement.nestedConstruct", nestedConstruct.arguments, Void, nestedConstruct.blocks), []);
		for (block in rewrittenNestedConstruct.blocks) for (located in block.instructions) switch located.value {
			case NewObject(_, "LaneInner" | "LaneOuter"): throw "A nested constructed snapshot must stay scalar";
			case ToDyn(out, _) if (Type.enumEq(out.type, Nullable(Obj("LaneInner")))): throw "An optional nested snapshot must stay scalar";
			default:
		}
		var nullConstruct = new IrBuilder(), nullConstructReceiver = nullConstruct.argument("this", element);
		var nullOuter = nullConstruct.newObject("LaneOuter");
		nullConstruct.fieldSet(nullOuter, "maybe", nullConstruct.constNull(Nullable(Obj("LaneInner"))));
		nullConstruct.fieldSet(nullConstructReceiver, "outer", nullOuter);
		nullConstruct.returnValue(nullConstruct.constVoid());
		var rewrittenNullConstruct = methodRewriter.specialize("array_place_null_construct",
			new IrFunction("LaneElement.nullConstruct", nullConstruct.arguments, Void, nullConstruct.blocks), []);
		if (methodRewriter.requests.length != 0) throw "Unexpected nested array-place method request";
		var adjustment = new IrBuilder(), adjustmentReceiver = adjustment.argument("this", Obj("LaneInner")),
			delta = adjustment.argument("delta", I32);
		var oldInner = adjustment.fieldGet(adjustmentReceiver, "value", I32);
		adjustment.fieldSet(adjustmentReceiver, "value", adjustment.add(oldInner, delta));
		adjustment.returnValue(adjustment.constVoid());
		var adjustmentFunction = new IrFunction("LaneInner.adjust", adjustment.arguments, Void, adjustment.blocks);
		var caller = new IrBuilder(), callerReceiver = caller.argument("this", element), callerDelta = caller.argument("delta", I32),
			callerChild = caller.fieldGet(callerReceiver, "inner", Obj("LaneInner"));
		caller.currentBlock().instructions.push(new Located(MethodCall(new IrValue(900000, "$nested-call", Void), callerChild, "adjust", [callerDelta]),
			SourceProvenance.generated("array-place-test")));
		caller.returnValue(caller.constVoid());
		var callerFunction = new IrFunction("LaneElement.nestedCall", caller.arguments, Void, caller.blocks);
		var callerName = methodRewriter.method(element, callerFunction.name, []);
		var placeCaller = new IrBuilder(), placeArray = placeCaller.argument("array", arrayType), placeIndex = placeCaller.argument("index", I32),
			placeDelta = placeCaller.argument("delta", I32), placeRoot = new IrValue(900000, "$element-place", element),
			placeProvenance = SourceProvenance.generated("array-place-caller-test");
		placeCaller.currentBlock().instructions.push(new Located(ArrayGet(placeRoot, placeArray, placeIndex), placeProvenance));
		var placeChild = placeCaller.fieldGet(placeRoot, "inner", Obj("LaneInner"));
		placeCaller.currentBlock().instructions.push(new Located(MethodCall(new IrValue(900001, "$place-adjust", Void), placeChild, "adjust", [placeDelta]), placeProvenance));
		placeCaller.currentBlock().instructions.push(new Located(ArraySet(placeArray, placeIndex, placeRoot), placeProvenance));
		placeCaller.returnValue(placeCaller.fieldGet(placeChild, "value", I32));
		var rewrittenPlaceCaller = compiler.ir.IrValueArrayPlaceRewrite.rewrite(
			new IrFunction("array_place_caller", placeCaller.arguments, I32, placeCaller.blocks), element, IrObjectTable.of(objects), helpers,
			methodRewriter, [placeRoot.id => true]);
		var growthCaller = new IrBuilder(), growthArray = growthCaller.argument("array", arrayType), growthIndex = growthCaller.argument("index", I32),
			growthCallback = growthCaller.argument("callback", callbackType), growthRoot = new IrValue(900002, "$growth-place", element);
		growthCaller.currentBlock().instructions.push(new Located(ArrayGet(growthRoot, growthArray, growthIndex), placeProvenance));
		growthCaller.currentBlock().instructions.push(new Located(MethodCall(new IrValue(900003, "$growth-method", Void), growthRoot,
			"LaneElement.nestedAround", [growthCallback, growthArray]), placeProvenance));
		growthCaller.currentBlock().instructions.push(new Located(ArraySet(growthArray, growthIndex, growthRoot), placeProvenance));
		growthCaller.returnValue(growthCaller.constVoid());
		var rewrittenGrowthCaller = compiler.ir.IrValueArrayPlaceRewrite.rewrite(
			new IrFunction("array_place_growth_caller", growthCaller.arguments, Void, growthCaller.blocks), element, IrObjectTable.of(objects), helpers,
			methodRewriter, [growthRoot.id => true]);
		var valueCaller = new IrBuilder(), valueArray = valueCaller.argument("array", arrayType), valueIndex = valueCaller.argument("index", I32),
			valuePair = valueCaller.argument("value", pairType), valueRoot = new IrValue(900005, "$value-place", element);
		valueCaller.currentBlock().instructions.push(new Located(ArrayGet(valueRoot, valueArray, valueIndex), placeProvenance));
		valueCaller.fieldSet(valueRoot, "pair", valuePair);
		valueCaller.currentBlock().instructions.push(new Located(ArraySet(valueArray, valueIndex, valueRoot), placeProvenance));
		valueCaller.returnValue(valueCaller.constVoid());
		var rewrittenValueCaller = compiler.ir.IrValueArrayPlaceRewrite.rewrite(
			new IrFunction("array_place_value_caller", valueCaller.arguments, Void, valueCaller.blocks), element, IrObjectTable.of(objects), helpers,
			methodRewriter, [valueRoot.id => true]);
		var escapingPlace = new IrBuilder(), escapingArray = escapingPlace.argument("array", arrayType), escapingIndex = escapingPlace.argument("index", I32),
			escapingRoot = new IrValue(900004, "$escaping-place", element);
		escapingPlace.currentBlock().instructions.push(new Located(ArrayGet(escapingRoot, escapingArray, escapingIndex), placeProvenance));
		escapingPlace.returnValue(escapingRoot);
		var rejectedEscape = false;
		try {
			compiler.ir.IrValueArrayPlaceRewrite.rewrite(new IrFunction("escaping_place", escapingPlace.arguments, element, escapingPlace.blocks),
				element, IrObjectTable.of(objects), helpers, methodRewriter, [escapingRoot.id => true]);
		} catch (_:Dynamic) rejectedEscape = true;
		if (!rejectedEscape) throw "An escaping array place must not be silently treated as a live alias";
		var nestedOriginal = new IrFunction("LaneElement.nestedAround", nestedMethod.arguments, Void, nestedMethod.blocks);
		var generatedMethods = methodRewriter.generate([callerFunction.name => callerFunction, adjustmentFunction.name => adjustmentFunction,
			nestedOriginal.name => nestedOriginal]);
		if (generatedMethods.length != 4) throw "Nested array-place method dispatch was not specialized";
		var helperFunctions = helpers.functions();
		builder.call(helpers.setter(0), [array, index, builder.constInt(257)], Void);
		builder.call(helpers.setter(1), [array, index, builder.constInt(-259)], Void);
		builder.call(helpers.setter(2), [array, index, owner], Void);
		var typeValue = builder.typeValue(Obj("LaneOwner"));
		builder.call(helpers.setter(3), [array, index, typeValue], Void);
		builder.call(helpers.setter(4), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(5), [array, index, builder.constInt(7)], Void);
		var nestedSlot = helpers.slot(["inner", "value"]);
		builder.call(helpers.setter(nestedSlot), [array, index, builder.constInt(10)], Void);
		var nestedLabel = helpers.slot(["inner", "label"]);
		builder.call(helpers.setter(nestedLabel), [array, index, owner], Void);
		var maybePresent = helpers.slot(["maybe"], true), maybeValue = helpers.slot(["maybe", "value"]);
		var maybeLabel = helpers.slot(["maybe", "label"]);
		var secondValue = helpers.slot(["inner2", "value"]), secondLabel = helpers.slot(["inner2", "label"]);
		var maybe2Present = helpers.slot(["maybe2"], true), maybe2Value = helpers.slot(["maybe2", "value"]),
			maybe2Label = helpers.slot(["maybe2", "label"]);
		var pairValue = helpers.slot(["pair", "value"]), pairLabel = helpers.slot(["pair", "label"]);
		var secondFlag = helpers.slot(["inner2", "flag"], true), secondFlagValue = helpers.slot(["inner2", "flag"], false, true),
			firstFlag = helpers.slot(["inner", "flag"], true), firstFlagValue = helpers.slot(["inner", "flag"], false, true),
			maybe2Flag = helpers.slot(["maybe2", "flag"], true), maybe2FlagValue = helpers.slot(["maybe2", "flag"], false, true),
			maybeFlag = helpers.slot(["maybe", "flag"], true), maybeFlagValue = helpers.slot(["maybe", "flag"], false, true);
		var outerValue = helpers.slot(["outer", "nested", "value"]), outerLabel = helpers.slot(["outer", "nested", "label"]),
			outerFlag = helpers.slot(["outer", "nested", "flag"], true), outerPayload = helpers.slot(["outer", "nested", "flag"], false, true),
			outerMaybe = helpers.slot(["outer", "maybe"], true), outerMaybeLabel = helpers.slot(["outer", "maybe", "label"]),
			outerMaybeValue = helpers.slot(["outer", "maybe", "value"]), outerMaybeFlag = helpers.slot(["outer", "maybe", "flag"], true),
			outerMaybePayload = helpers.slot(["outer", "maybe", "flag"], false, true);
		builder.call(helpers.setter(secondValue), [array, index, builder.constInt(99)], Void);
		builder.call(helpers.setter(secondLabel), [array, index, otherOwner], Void);
		builder.call(helpers.setter(secondFlag), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(secondFlagValue), [array, index, builder.constInt(-7)], Void);
		builder.call(helpers.setter(maybe2Present), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(maybe2Value), [array, index, builder.constInt(71)], Void);
		builder.call(helpers.setter(maybe2Label), [array, index, otherOwner], Void);
		builder.call(helpers.setter(maybe2Flag), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(maybe2FlagValue), [array, index, builder.constInt(-5)], Void);
		builder.call(helpers.setter(maybePresent), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(maybeValue), [array, index, builder.constInt(40)], Void);
		builder.call(helpers.setter(maybeLabel), [array, index, owner], Void);
		builder.call("__value_array_mark", [array, index], Void);
		builder.call(checkOptional, [array, index], Void);

		builder.call(helpers.getter(1), [array, index], shape.slots[1].type);
		builder.call(helpers.getter(2), [array, index], shape.slots[2].type);
		var before = builder.call("std.gc_total_allocated", [], F64);
		for (_ in 0...1000) {
			builder.call(helpers.setter(1), [array, index, builder.constInt(-259)], Void);
			builder.call(helpers.setter(2), [array, index, owner], Void);
			builder.call(helpers.getter(1), [array, index], shape.slots[1].type);
			builder.call(helpers.getter(2), [array, index], shape.slots[2].type);
		}
		var after = builder.call("std.gc_total_allocated", [], F64);
		var tiny = builder.call(helpers.getter(0), [array, index], shape.slots[0].type);
		var signed = builder.call(helpers.getter(1), [array, index], shape.slots[1].type);
		var restored = builder.call(helpers.getter(2), [array, index], shape.slots[2].type);
		var restoredType = builder.call(helpers.getter(3), [array, index], shape.slots[3].type);
		var callbackClosure = builder.staticClosure("array_place_callback", callbackType);
		builder.call(rewrittenMethod.name, [array, index, callbackClosure, array], Void);
		var changed = builder.call(helpers.getter(1), [array, index], I32);
		var nestedClosure = builder.staticClosure("array_place_nested_callback", callbackType);
		builder.call(rewrittenGrowthCaller.name, [array, index, nestedClosure], Void);
		var nestedChanged = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		builder.call(callerName, [array, index, builder.constInt(5)], Void);
		var afterNestedCall = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		var beforePlaceCaller = builder.call("std.gc_total_allocated", [], F64);
		var placeCallerResult = builder.call(rewrittenPlaceCaller.name, [array, index, builder.constInt(5)], I32);
		for (_ in 0...1000) builder.call(rewrittenPlaceCaller.name, [array, index, builder.constInt(0)], I32);
		var afterPlaceCaller = builder.call("std.gc_total_allocated", [], F64);
		builder.call(helpers.setter(nestedSlot), [array, index, builder.constInt(37)], Void);
		var beforeMethods = builder.call("std.gc_total_allocated", [], F64);
		for (_ in 0...1000) builder.call(callerName, [array, index, builder.constInt(0)], Void);
		var afterMethods = builder.call("std.gc_total_allocated", [], F64);
		var snapshotClosure = builder.staticClosure("array_place_snapshot_callback", callbackType);
		var beforeSnapshot = builder.call("std.gc_total_allocated", [], F64);
		var saved = builder.call(rewrittenSnapshot.name, [array, index, snapshotClosure, array], I32);
		var afterSnapshot = builder.call("std.gc_total_allocated", [], F64);
		var current = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		var scalarClosure = builder.staticClosure("array_place_scalar_callback", callbackType);
		var beforeScalars = builder.call("std.gc_total_allocated", [], F64);
		var savedScalarValue = builder.call(rewrittenScalarSnapshot.name, [array, index, scalarClosure, array], I32);
		var scalarAfterCallback = builder.call(helpers.getter(5), [array, index], I32);
		var assignedScalarValue = builder.call(rewrittenScalarWrite.name, [array, index], I32);
		var afterScalars = builder.call("std.gc_total_allocated", [], F64);
		builder.call(helpers.setter(4), [array, index, builder.constBool(false)], Void);
		var beforeNullSnapshot = builder.call("std.gc_total_allocated", [], F64);
		var savedNullResult = builder.call(rewrittenScalarNull.name, [array, index, scalarClosure, array], I32);
		var afterNullSnapshot = builder.call("std.gc_total_allocated", [], F64);
		builder.call(helpers.setter(5), [array, index, builder.constInt(7)], Void);
		builder.call(helpers.setter(4), [array, index, builder.constBool(true)], Void);
		var beforePhi = builder.call("std.gc_total_allocated", [], F64);
		var phiSaved = builder.call(rewrittenPhiRead.name, [array, index, builder.constBool(true), scalarClosure, array], I32);
		var phiMissing = builder.call(rewrittenPhiRead.name, [array, index, builder.constBool(false), scalarClosure, array], I32);
		var phiWritten = builder.call(rewrittenPhiWrite.name, [array, index, builder.constBool(true)], I32);
		var phiCleared = builder.call(rewrittenPhiWrite.name, [array, index, builder.constBool(false)], I32);
		var afterPhi = builder.call("std.gc_total_allocated", [], F64);
		var optionalResult = builder.call(rewrittenOptional.name, [array, index], I32);
		builder.call(helpers.setter(maybePresent), [array, index, builder.constBool(false)], Void);
		var absentResult = builder.call(rewrittenOptional.name, [array, index], I32);
		var clearedValue = builder.call(helpers.getter(maybeValue), [array, index], I32);
		var clearedLabel = builder.call(helpers.getter(maybeLabel), [array, index], Obj("LaneOwner"));
		var retainedLabel = builder.call(helpers.getter(nestedLabel), [array, index], Obj("LaneOwner"));
		var beforeCopies = builder.call("std.gc_total_allocated", [], F64);
		for (_ in 0...1000) {
			builder.call(rewrittenCopy.name, [array, index], Void);
			builder.call(rewrittenSelf.name, [array, index], Void);
			builder.call(rewrittenConstruct.name, [array, index, builder.constInt(61), otherOwner], Void);
		}
		builder.call(rewrittenOptionalCopy.name, [array, index], Void);
		var copiedValue = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		var copiedLabel = builder.call(helpers.getter(nestedLabel), [array, index], Obj("LaneOwner"));
		var copiedFlag = builder.call(helpers.getter(firstFlag), [array, index], Bool);
		var copiedFlagValue = builder.call(helpers.getter(firstFlagValue), [array, index], I32);
		var copiedOptionalPresent = builder.call(helpers.getter(maybePresent), [array, index], Bool);
		var copiedOptionalValue = builder.call(helpers.getter(maybeValue), [array, index], I32);
		var copiedOptionalLabel = builder.call(helpers.getter(maybeLabel), [array, index], Obj("LaneOwner"));
		var copiedOptionalFlag = builder.call(helpers.getter(maybeFlag), [array, index], Bool);
		var copiedOptionalFlagValue = builder.call(helpers.getter(maybeFlagValue), [array, index], I32);
		builder.call(helpers.setter(maybe2Present), [array, index, builder.constBool(false)], Void);
		builder.call(rewrittenOptionalCopy.name, [array, index], Void);
		var copiedAbsent = builder.call(helpers.getter(maybePresent), [array, index], Bool);
		var copiedCleared = builder.call(helpers.getter(maybeLabel), [array, index], Obj("LaneOwner"));
		var clearedOptionalFlag = builder.call(helpers.getter(maybeFlag), [array, index], Bool);
		var constructedValue = builder.call(helpers.getter(pairValue), [array, index], I32);
		var constructedLabel = builder.call(helpers.getter(pairLabel), [array, index], Obj("LaneOwner"));
		var afterCopies = builder.call("std.gc_total_allocated", [], F64);
		var beforeArguments = builder.call("std.gc_total_allocated", [], F64);
		for (_ in 0...10) {
			var pair = builder.newObject("LanePair");
			builder.fieldSet(pair, "value", builder.constInt(72));
			builder.fieldSet(pair, "label", owner);
			builder.call(rewrittenArgument.name, [array, index, pair], Void);
		}
		var afterArguments = builder.call("std.gc_total_allocated", [], F64);
		var argumentValue = builder.call(helpers.getter(pairValue), [array, index], I32);
		var argumentLabel = builder.call(helpers.getter(pairLabel), [array, index], Obj("LaneOwner"));
		var beforeValueCaller = builder.call("std.gc_total_allocated", [], F64);
		for (_ in 0...10) {
			var value = builder.newObject("LanePair");
			builder.fieldSet(value, "value", builder.constInt(83));
			builder.fieldSet(value, "label", otherOwner);
			builder.call(rewrittenValueCaller.name, [array, index, value], Void);
		}
		var afterValueCaller = builder.call("std.gc_total_allocated", [], F64);
		var copiedPairValue = builder.call(helpers.getter(pairValue), [array, index], I32);
		var copiedPairLabel = builder.call(helpers.getter(pairLabel), [array, index], Obj("LaneOwner"));
		var compositeClosure = builder.staticClosure("array_place_composite_callback", callbackType);
		var beforeComposite = builder.call("std.gc_total_allocated", [], F64);
		builder.call(rewrittenComposite.name, [array, index, compositeClosure, array], Void);
		var afterComposite = builder.call("std.gc_total_allocated", [], F64);
		var compositeValue = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		var compositeLabel = builder.call(helpers.getter(nestedLabel), [array, index], Obj("LaneOwner"));
		var compositeFlag = builder.call(helpers.getter(firstFlag), [array, index], Bool);
		var compositeFlagValue = builder.call(helpers.getter(firstFlagValue), [array, index], I32);
		var compositeSourceValue = builder.call(helpers.getter(secondValue), [array, index], I32);
		var compositeSourceFlag = builder.call(helpers.getter(secondFlag), [array, index], Bool);
		var beforeDefaults = builder.call("std.gc_total_allocated", [], F64);
		builder.call(rewrittenDefaults.name, [array, index], Void);
		var afterDefaults = builder.call("std.gc_total_allocated", [], F64);
		var defaultValue = builder.call(helpers.getter(nestedSlot), [array, index], I32);
		var defaultLabel = builder.call(helpers.getter(nestedLabel), [array, index], Obj("LaneOwner"));
		var defaultFlag = builder.call(helpers.getter(firstFlag), [array, index], Bool);
		var defaultPayload = builder.call(helpers.getter(firstFlagValue), [array, index], I32);
		builder.call(helpers.setter(outerValue), [array, index, builder.constInt(17)], Void);
		builder.call(helpers.setter(outerLabel), [array, index, owner], Void);
		builder.call(helpers.setter(outerFlag), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(outerPayload), [array, index, builder.constInt(9)], Void);
		builder.call(helpers.setter(outerMaybe), [array, index, builder.constBool(true)], Void);
		builder.call(helpers.setter(outerMaybeLabel), [array, index, owner], Void);
		var beforeNestedDefaults = builder.call("std.gc_total_allocated", [], F64);
		builder.call(rewrittenNestedDefaults.name, [array, index], Void);
		var afterNestedDefaults = builder.call("std.gc_total_allocated", [], F64);
		var nestedDefaultValue = builder.call(helpers.getter(outerValue), [array, index], I32);
		var nestedDefaultLabel = builder.call(helpers.getter(outerLabel), [array, index], Obj("LaneOwner"));
		var nestedDefaultFlag = builder.call(helpers.getter(outerFlag), [array, index], Bool);
		var nestedDefaultPayload = builder.call(helpers.getter(outerPayload), [array, index], I32);
		var nestedDefaultMaybe = builder.call(helpers.getter(outerMaybe), [array, index], Bool);
		var nestedDefaultMaybeLabel = builder.call(helpers.getter(outerMaybeLabel), [array, index], Obj("LaneOwner"));
		var beforeNestedConstruct = builder.call("std.gc_total_allocated", [], F64);
		builder.call(rewrittenNestedConstruct.name, [array, index, owner], Void);
		var afterNestedConstruct = builder.call("std.gc_total_allocated", [], F64);
		var nestedConstructValue = builder.call(helpers.getter(outerValue), [array, index], I32);
		var nestedConstructLabelValue = builder.call(helpers.getter(outerLabel), [array, index], Obj("LaneOwner"));
		var nestedConstructFlag = builder.call(helpers.getter(outerFlag), [array, index], Bool);
		var nestedConstructPayload = builder.call(helpers.getter(outerPayload), [array, index], I32);
		var optionalConstructPresent = builder.call(helpers.getter(outerMaybe), [array, index], Bool);
		var optionalConstructValue = builder.call(helpers.getter(outerMaybeValue), [array, index], I32);
		var optionalConstructLabel = builder.call(helpers.getter(outerMaybeLabel), [array, index], Obj("LaneOwner"));
		var optionalConstructFlag = builder.call(helpers.getter(outerMaybeFlag), [array, index], Bool);
		var optionalConstructPayload = builder.call(helpers.getter(outerMaybePayload), [array, index], I32);
		var beforeNullConstruct = builder.call("std.gc_total_allocated", [], F64);
		builder.call(rewrittenNullConstruct.name, [array, index], Void);
		var afterNullConstruct = builder.call("std.gc_total_allocated", [], F64);
		var nullConstructPresent = builder.call(helpers.getter(outerMaybe), [array, index], Bool);
		var nullConstructLabel = builder.call(helpers.getter(outerMaybeLabel), [array, index], Obj("LaneOwner"));
		var checkTiny = builder.createBlock(), checkSigned = builder.createBlock(), checkOwner = builder.createBlock();
		var checkMethod = builder.createBlock(), checkNested = builder.createBlock(), checkNestedCall = builder.createBlock(), checkPlaceCaller = builder.createBlock(),
			checkPlaceCallerAlloc = builder.createBlock(), checkMethodAlloc = builder.createBlock(),
			checkSnapshot = builder.createBlock(), checkSnapshotValue = builder.createBlock(), checkCurrent = builder.createBlock(),
			checkScalarAlloc = builder.createBlock(), checkScalarSaved = builder.createBlock(), checkScalarCurrent = builder.createBlock(),
			checkScalarWrite = builder.createBlock(), checkNullAlloc = builder.createBlock(), checkNullSnapshot = builder.createBlock(),
			checkPhiAlloc = builder.createBlock(), checkPhiSaved = builder.createBlock(), checkPhiMissing = builder.createBlock(),
			checkPhiWritten = builder.createBlock(), checkPhiCleared = builder.createBlock(),
			checkOptionalValue = builder.createBlock(), checkOptionalAbsent = builder.createBlock(),
			checkClearedValue = builder.createBlock(), checkCleared = builder.createBlock(),
			checkRetained = builder.createBlock(), checkCopyAlloc = builder.createBlock(), checkCopiedValue = builder.createBlock(),
			checkCopiedLabel = builder.createBlock(), checkCopiedFlag = builder.createBlock(), checkCopiedFlagValue = builder.createBlock(),
			checkCopiedPresent = builder.createBlock(), checkCopiedOptionalValue = builder.createBlock(), checkCopiedOptionalLabel = builder.createBlock(),
			checkCopiedOptionalFlag = builder.createBlock(), checkCopiedOptionalFlagValue = builder.createBlock(), checkCopiedAbsent = builder.createBlock(),
			checkCopiedCleared = builder.createBlock(), checkClearedOptionalFlag = builder.createBlock(), checkConstructedValue = builder.createBlock(),
			checkConstructedLabel = builder.createBlock(), checkArgumentAlloc = builder.createBlock(),
			checkArgumentValue = builder.createBlock(), checkArgumentLabel = builder.createBlock(),
			checkValueCallerAlloc = builder.createBlock(), checkValueCallerValue = builder.createBlock(), checkValueCallerLabel = builder.createBlock(),
			checkCompositeAlloc = builder.createBlock(), checkCompositeValue = builder.createBlock(),
			checkCompositeLabel = builder.createBlock(), checkCompositeFlag = builder.createBlock(),
			checkCompositeFlagValue = builder.createBlock(), checkCompositeSource = builder.createBlock(),
			checkCompositeSourceFlag = builder.createBlock(), checkDefaultAlloc = builder.createBlock(),
			checkDefaultValue = builder.createBlock(), checkDefaultLabel = builder.createBlock(),
			checkDefaultFlag = builder.createBlock(), checkDefaultPayload = builder.createBlock(),
			checkNestedDefaultAlloc = builder.createBlock(), checkNestedDefaultValue = builder.createBlock(),
			checkNestedDefaultLabel = builder.createBlock(), checkNestedDefaultFlag = builder.createBlock(),
			checkNestedDefaultPayload = builder.createBlock(), checkNestedDefaultMaybe = builder.createBlock(),
			checkNestedDefaultMaybeLabel = builder.createBlock(), checkNestedConstructAlloc = builder.createBlock(),
			checkNestedConstructValue = builder.createBlock(), checkNestedConstructLabel = builder.createBlock(),
			checkNestedConstructFlag = builder.createBlock(), checkNestedConstructPayload = builder.createBlock(),
			checkOptionalConstructPresent = builder.createBlock(), checkOptionalConstructValue = builder.createBlock(),
			checkOptionalConstructLabel = builder.createBlock(), checkOptionalConstructFlag = builder.createBlock(),
			checkOptionalConstructPayload = builder.createBlock(), checkNullConstructAlloc = builder.createBlock(),
			checkNullConstructPresent = builder.createBlock(), checkNullConstructLabel = builder.createBlock(),
			checkBridgeAccepted = builder.createBlock(), checkBridgeRejected = builder.createBlock(), checkBridgeNullRejected = builder.createBlock(),
			checkBridgeValue = builder.createBlock(), checkBridgeLabel = builder.createBlock(),
			checkEscapedPairValue = builder.createBlock(), checkEscapedPairLabel = builder.createBlock(),
			checkOptionalBridgeNullAccepted = builder.createBlock(), checkOptionalBridgeAccepted = builder.createBlock(),
			checkOptionalBridgeValue = builder.createBlock(), checkOptionalBridgeLabel = builder.createBlock(),
			checkOptionalSnapshotAlloc = builder.createBlock(), checkOptionalSnapshotValue = builder.createBlock(), checkOptionalSnapshotCurrent = builder.createBlock(),
			checkOptionalPushAlloc = builder.createBlock(), checkOptionalFrontPresent = builder.createBlock(), checkOptionalFrontRef = builder.createBlock(),
			checkOptionalInsertedValue = builder.createBlock(), checkOptionalInsertedRef = builder.createBlock(), checkOptionalLastValue = builder.createBlock(),
			checkOptionalBridgeNull = builder.createBlock(), checkOptionalBridgeCleared = builder.createBlock(),
			checkNestedBridgeValue = builder.createBlock(), checkNestedBridgeLabel = builder.createBlock(),
			checkNestedBridgePayload = builder.createBlock(), checkNestedBridgeNull = builder.createBlock(),
			checkOuterBridgeValue = builder.createBlock(), checkOuterBridgeOwner = builder.createBlock(),
			checkOuterBridgeFlag = builder.createBlock(), checkOuterBridgeNull = builder.createBlock(), checkOuterBridgeCleared = builder.createBlock(),
			checkRetypedInitial = builder.createBlock(), checkRetypedWrite = builder.createBlock(), checkRetypedSize = builder.createBlock(),
			checkTypedElementAlloc = builder.createBlock(), checkTypedElementValue = builder.createBlock(), checkTypedElementLabel = builder.createBlock(),
			checkTypedPushAlloc = builder.createBlock(), checkTypedPushLength = builder.createBlock(),
			checkTypedPushValue = builder.createBlock(), checkTypedPushLabel = builder.createBlock(),
			checkTypedInsertAlloc = builder.createBlock(), checkTypedUnshiftLength = builder.createBlock(),
			checkTypedInsertValue = builder.createBlock(), checkTypedInsertLabel = builder.createBlock(),
			checkTypedFrontValue = builder.createBlock(), checkTypedFrontLabel = builder.createBlock(),
			checkTypedRangesAlloc = builder.createBlock(), checkTypedRangesValidity = builder.createBlock(),
			checkRemovedPairValue = builder.createBlock(), checkRemovedPairLabel = builder.createBlock(),
			checkType = builder.createBlock(),
			success = builder.createBlock(), failure = builder.createBlock();
		builder.branch(builder.equal(before, after), checkTiny, failure);
		builder.select(checkTiny); builder.branch(builder.equal(tiny, builder.constInt(1)), checkSigned, failure);
		builder.select(checkSigned); builder.branch(builder.equal(signed, builder.constInt(-259)), checkOwner, failure);
		builder.select(checkOwner); builder.branch(builder.equal(owner, restored), checkMethod, failure);
		builder.select(checkMethod); builder.branch(builder.equal(changed, builder.constInt(22)), checkNested, failure);
		builder.select(checkNested); builder.branch(builder.equal(nestedChanged, builder.constInt(32)), checkNestedCall, failure);
		builder.select(checkNestedCall); builder.branch(builder.equal(afterNestedCall, builder.constInt(37)), checkPlaceCaller, failure);
		builder.select(checkPlaceCaller); builder.branch(builder.equal(placeCallerResult, builder.constInt(42)), checkPlaceCallerAlloc, failure);
		builder.select(checkPlaceCallerAlloc); builder.branch(builder.equal(beforePlaceCaller, afterPlaceCaller), checkMethodAlloc, failure);
		builder.select(checkMethodAlloc); builder.branch(builder.equal(beforeMethods, afterMethods), checkSnapshot, failure);
		builder.select(checkSnapshot); builder.branch(builder.equal(beforeSnapshot, afterSnapshot), checkSnapshotValue, failure);
		builder.select(checkSnapshotValue); builder.branch(builder.equal(saved, builder.constInt(37)), checkCurrent, failure);
		builder.select(checkCurrent); builder.branch(builder.equal(current, builder.constInt(50)), checkScalarAlloc, failure);
		builder.select(checkScalarAlloc); builder.branch(builder.equal(beforeScalars, afterScalars), checkScalarSaved, failure);
		builder.select(checkScalarSaved); builder.branch(builder.equal(savedScalarValue, builder.constInt(7)), checkScalarCurrent, failure);
		builder.select(checkScalarCurrent); builder.branch(builder.equal(scalarAfterCallback, builder.constInt(20)), checkScalarWrite, failure);
		builder.select(checkScalarWrite); builder.branch(builder.equal(assignedScalarValue, builder.constInt(1)), checkNullAlloc, failure);
		builder.select(checkNullAlloc); builder.branch(builder.equal(beforeNullSnapshot, afterNullSnapshot), checkNullSnapshot, failure);
		builder.select(checkNullSnapshot); builder.branch(builder.equal(savedNullResult, builder.constInt(42)), checkPhiAlloc, failure);
		builder.select(checkPhiAlloc); builder.branch(builder.equal(beforePhi, afterPhi), checkPhiSaved, failure);
		builder.select(checkPhiSaved); builder.branch(builder.equal(phiSaved, builder.constInt(7)), checkPhiMissing, failure);
		builder.select(checkPhiMissing); builder.branch(builder.equal(phiMissing, builder.constInt(0)), checkPhiWritten, failure);
		builder.select(checkPhiWritten); builder.branch(builder.equal(phiWritten, builder.constInt(1)), checkPhiCleared, failure);
		builder.select(checkPhiCleared); builder.branch(builder.equal(phiCleared, builder.constInt(0)), checkOptionalValue, failure);
		builder.select(checkOptionalValue); builder.branch(builder.equal(optionalResult, builder.constInt(42)), checkOptionalAbsent, failure);
		builder.select(checkOptionalAbsent); builder.branch(builder.equal(absentResult, builder.constInt(0)), checkClearedValue, failure);
		builder.select(checkClearedValue); builder.branch(builder.equal(clearedValue, builder.constInt(0)), checkCleared, failure);
		builder.select(checkCleared); builder.branch(builder.equal(clearedLabel, builder.constNull(Obj("LaneOwner"))), checkRetained, failure);
		builder.select(checkRetained); builder.branch(builder.equal(retainedLabel, owner), checkCopyAlloc, failure);
		builder.select(checkCopyAlloc); builder.branch(builder.equal(beforeCopies, afterCopies), checkCopiedValue, failure);
		builder.select(checkCopiedValue); builder.branch(builder.equal(copiedValue, builder.constInt(99)), checkCopiedLabel, failure);
		builder.select(checkCopiedLabel); builder.branch(builder.equal(copiedLabel, otherOwner), checkCopiedFlag, failure);
		builder.select(checkCopiedFlag); builder.branch(copiedFlag, checkCopiedFlagValue, failure);
		builder.select(checkCopiedFlagValue); builder.branch(builder.equal(copiedFlagValue, builder.constInt(-7)), checkCopiedPresent, failure);
		builder.select(checkCopiedPresent); builder.branch(copiedOptionalPresent, checkCopiedOptionalValue, failure);
		builder.select(checkCopiedOptionalValue); builder.branch(builder.equal(copiedOptionalValue, builder.constInt(71)), checkCopiedOptionalLabel, failure);
		builder.select(checkCopiedOptionalLabel); builder.branch(builder.equal(copiedOptionalLabel, otherOwner), checkCopiedOptionalFlag, failure);
		builder.select(checkCopiedOptionalFlag); builder.branch(copiedOptionalFlag, checkCopiedOptionalFlagValue, failure);
		builder.select(checkCopiedOptionalFlagValue); builder.branch(builder.equal(copiedOptionalFlagValue, builder.constInt(-5)), checkCopiedAbsent, failure);
		builder.select(checkCopiedAbsent); builder.branch(copiedAbsent, failure, checkCopiedCleared);
		builder.select(checkCopiedCleared); builder.branch(builder.equal(copiedCleared, builder.constNull(Obj("LaneOwner"))), checkClearedOptionalFlag, failure);
		builder.select(checkClearedOptionalFlag); builder.branch(clearedOptionalFlag, failure, checkConstructedValue);
		builder.select(checkConstructedValue); builder.branch(builder.equal(constructedValue, builder.constInt(61)), checkConstructedLabel, failure);
		builder.select(checkConstructedLabel); builder.branch(builder.equal(constructedLabel, otherOwner), checkArgumentAlloc, failure);
		builder.select(checkArgumentAlloc); builder.branch(builder.equal(beforeArguments, afterArguments), checkArgumentValue, failure);
		builder.select(checkArgumentValue); builder.branch(builder.equal(argumentValue, builder.constInt(72)), checkArgumentLabel, failure);
		builder.select(checkArgumentLabel); builder.branch(builder.equal(argumentLabel, owner), checkValueCallerAlloc, failure);
		builder.select(checkValueCallerAlloc); builder.branch(builder.equal(beforeValueCaller, afterValueCaller), checkValueCallerValue, failure);
		builder.select(checkValueCallerValue); builder.branch(builder.equal(copiedPairValue, builder.constInt(83)), checkValueCallerLabel, failure);
		builder.select(checkValueCallerLabel); builder.branch(builder.equal(copiedPairLabel, otherOwner), checkCompositeAlloc, failure);
		builder.select(checkCompositeAlloc); builder.branch(builder.equal(beforeComposite, afterComposite), checkCompositeValue, failure);
		builder.select(checkCompositeValue); builder.branch(builder.equal(compositeValue, builder.constInt(99)), checkCompositeLabel, failure);
		builder.select(checkCompositeLabel); builder.branch(builder.equal(compositeLabel, otherOwner), checkCompositeFlag, failure);
		builder.select(checkCompositeFlag); builder.branch(compositeFlag, checkCompositeFlagValue, failure);
		builder.select(checkCompositeFlagValue); builder.branch(builder.equal(compositeFlagValue, builder.constInt(-7)), checkCompositeSource, failure);
		builder.select(checkCompositeSource); builder.branch(builder.equal(compositeSourceValue, builder.constInt(120)), checkCompositeSourceFlag, failure);
		builder.select(checkCompositeSourceFlag); builder.branch(compositeSourceFlag, failure, checkDefaultAlloc);
		builder.select(checkDefaultAlloc); builder.branch(builder.equal(beforeDefaults, afterDefaults), checkDefaultValue, failure);
		builder.select(checkDefaultValue); builder.branch(builder.equal(defaultValue, builder.constInt(0)), checkDefaultLabel, failure);
		builder.select(checkDefaultLabel); builder.branch(builder.equal(defaultLabel, builder.constNull(Obj("LaneOwner"))), checkDefaultFlag, failure);
		builder.select(checkDefaultFlag); builder.branch(defaultFlag, failure, checkDefaultPayload);
		builder.select(checkDefaultPayload); builder.branch(builder.equal(defaultPayload, builder.constInt(0)), checkNestedDefaultAlloc, failure);
		builder.select(checkNestedDefaultAlloc); builder.branch(builder.equal(beforeNestedDefaults, afterNestedDefaults), checkNestedDefaultValue, failure);
		builder.select(checkNestedDefaultValue); builder.branch(builder.equal(nestedDefaultValue, builder.constInt(0)), checkNestedDefaultLabel, failure);
		builder.select(checkNestedDefaultLabel); builder.branch(builder.equal(nestedDefaultLabel, builder.constNull(Obj("LaneOwner"))), checkNestedDefaultFlag, failure);
		builder.select(checkNestedDefaultFlag); builder.branch(nestedDefaultFlag, failure, checkNestedDefaultPayload);
		builder.select(checkNestedDefaultPayload); builder.branch(builder.equal(nestedDefaultPayload, builder.constInt(0)), checkNestedDefaultMaybe, failure);
		builder.select(checkNestedDefaultMaybe); builder.branch(nestedDefaultMaybe, failure, checkNestedDefaultMaybeLabel);
		builder.select(checkNestedDefaultMaybeLabel); builder.branch(builder.equal(nestedDefaultMaybeLabel, builder.constNull(Obj("LaneOwner"))), checkNestedConstructAlloc, failure);
		builder.select(checkNestedConstructAlloc); builder.branch(builder.equal(beforeNestedConstruct, afterNestedConstruct), checkNestedConstructValue, failure);
		builder.select(checkNestedConstructValue); builder.branch(builder.equal(nestedConstructValue, builder.constInt(23)), checkNestedConstructLabel, failure);
		builder.select(checkNestedConstructLabel); builder.branch(builder.equal(nestedConstructLabelValue, owner), checkNestedConstructFlag, failure);
		builder.select(checkNestedConstructFlag); builder.branch(nestedConstructFlag, checkNestedConstructPayload, failure);
		builder.select(checkNestedConstructPayload); builder.branch(builder.equal(nestedConstructPayload, builder.constInt(5)), checkOptionalConstructPresent, failure);
		builder.select(checkOptionalConstructPresent); builder.branch(optionalConstructPresent, checkOptionalConstructValue, failure);
		builder.select(checkOptionalConstructValue); builder.branch(builder.equal(optionalConstructValue, builder.constInt(23)), checkOptionalConstructLabel, failure);
		builder.select(checkOptionalConstructLabel); builder.branch(builder.equal(optionalConstructLabel, owner), checkOptionalConstructFlag, failure);
		builder.select(checkOptionalConstructFlag); builder.branch(optionalConstructFlag, checkOptionalConstructPayload, failure);
		builder.select(checkOptionalConstructPayload); builder.branch(builder.equal(optionalConstructPayload, builder.constInt(5)), checkNullConstructAlloc, failure);
		builder.select(checkNullConstructAlloc); builder.branch(builder.equal(beforeNullConstruct, afterNullConstruct), checkNullConstructPresent, failure);
		builder.select(checkNullConstructPresent); builder.branch(nullConstructPresent, failure, checkNullConstructLabel);
		builder.select(checkNullConstructLabel); builder.branch(builder.equal(nullConstructLabel, builder.constNull(Obj("LaneOwner"))), checkBridgeAccepted, failure);
		builder.select(checkBridgeAccepted); builder.branch(bridgeAccepted, checkBridgeRejected, failure);
		builder.select(checkBridgeRejected); builder.branch(bridgeRejected, failure, checkBridgeNullRejected);
		builder.select(checkBridgeNullRejected); builder.branch(bridgeNullRejected, failure, checkBridgeValue);
		builder.select(checkBridgeValue); builder.branch(builder.equal(bridgeValue, builder.constInt(314)), checkBridgeLabel, failure);
		builder.select(checkBridgeLabel); builder.branch(builder.equal(bridgeLabel, owner), checkEscapedPairValue, failure);
		builder.select(checkEscapedPairValue); builder.branch(builder.equal(escapedPairValue, builder.constInt(271)), checkEscapedPairLabel, failure);
		builder.select(checkEscapedPairLabel); builder.branch(builder.equal(escapedPairLabel, owner), checkOptionalBridgeNullAccepted, failure);
		builder.select(checkOptionalBridgeNullAccepted); builder.branch(optionalBridgeNullAccepted, checkOptionalBridgeAccepted, failure);
		builder.select(checkOptionalBridgeAccepted); builder.branch(optionalBridgeAccepted, checkOptionalBridgeValue, failure);
		builder.select(checkOptionalBridgeValue); builder.branch(builder.equal(optionalBridgeValue, builder.constInt(271)), checkOptionalBridgeLabel, failure);
		builder.select(checkOptionalBridgeLabel); builder.branch(builder.equal(optionalBridgeLabel, owner), checkOptionalSnapshotAlloc, failure);
		builder.select(checkOptionalSnapshotAlloc); builder.branch(builder.equal(beforeOptionalSnapshot, afterOptionalSnapshot), checkOptionalSnapshotValue, failure);
		builder.select(checkOptionalSnapshotValue); builder.branch(builder.equal(optionalSnapshotValue, builder.constInt(271)), checkOptionalSnapshotCurrent, failure);
		builder.select(checkOptionalSnapshotCurrent); builder.branch(builder.equal(optionalSnapshotCurrent, builder.constInt(999)), checkOptionalBridgeNull, failure);
		builder.select(checkOptionalBridgeNull); builder.branch(builder.equal(optionalBridgeNull, builder.constNull(Dyn)), checkOptionalBridgeCleared, failure);
		builder.select(checkOptionalBridgeCleared); builder.branch(builder.equal(optionalBridgeCleared, builder.constNull(Obj("LaneOwner"))), checkOptionalPushAlloc, failure);
		builder.select(checkOptionalPushAlloc); builder.branch(builder.equal(beforeOptionalPush, afterOptionalPush), checkOptionalFrontPresent, failure);
		builder.select(checkOptionalFrontPresent); builder.branch(optionalFrontPresent, failure, checkOptionalFrontRef);
		builder.select(checkOptionalFrontRef); builder.branch(builder.equal(optionalFrontRef, builder.constNull(Obj("LaneOwner"))), checkOptionalInsertedValue, failure);
		builder.select(checkOptionalInsertedValue); builder.branch(builder.equal(optionalInsertedValue, builder.constInt(42)), checkOptionalInsertedRef, failure);
		builder.select(checkOptionalInsertedRef); builder.branch(builder.equal(optionalInsertedRef, otherOwner), checkOptionalLastValue, failure);
		builder.select(checkOptionalLastValue); builder.branch(builder.equal(optionalLastValue, builder.constInt(19)), checkNestedBridgeValue, failure);
		builder.select(checkNestedBridgeValue); builder.branch(builder.equal(nestedBridgeValue, builder.constInt(271)), checkNestedBridgeLabel, failure);
		builder.select(checkNestedBridgeLabel); builder.branch(builder.equal(nestedBridgeLabel, owner), checkNestedBridgePayload, failure);
		builder.select(checkNestedBridgePayload); builder.branch(builder.equal(nestedBridgePayload, builder.constInt(93)), checkNestedBridgeNull, failure);
		builder.select(checkNestedBridgeNull); builder.branch(builder.equal(nestedBridgeNull, builder.constNull(Nullable(I32))), checkOuterBridgeValue, failure);
		builder.select(checkOuterBridgeValue); builder.branch(builder.equal(bridgeOuterValue, builder.constInt(45)), checkOuterBridgeOwner, failure);
		builder.select(checkOuterBridgeOwner); builder.branch(builder.equal(bridgeOuterOwner, owner), checkOuterBridgeFlag, failure);
		builder.select(checkOuterBridgeFlag); builder.branch(builder.equal(bridgeOuterFlag, builder.constInt(-7)), checkOuterBridgeNull, failure);
		builder.select(checkOuterBridgeNull); builder.branch(builder.equal(outerNull, builder.constNull(Nullable(Obj("LaneInner")))), checkOuterBridgeCleared, failure);
		builder.select(checkOuterBridgeCleared); builder.branch(builder.equal(outerCleared, builder.constNull(Obj("LaneOwner"))), checkRetypedInitial, failure);
		builder.select(checkRetypedInitial); builder.branch(builder.equal(retypedInitial, builder.constInt(271)), checkRetypedWrite, failure);
		builder.select(checkRetypedWrite); builder.branch(builder.equal(retypedAfterAliasWrite, builder.constInt(512)), checkRetypedSize, failure);
		builder.select(checkRetypedSize); builder.branch(builder.equal(retypedSize, builder.constInt(2)), checkTypedElementAlloc, failure);
		builder.select(checkTypedElementAlloc); builder.branch(builder.equal(beforeTypedElements, afterTypedElements), checkTypedElementValue, failure);
		builder.select(checkTypedElementValue); builder.branch(builder.equal(typedElementValue, builder.constInt(753)), checkTypedElementLabel, failure);
		builder.select(checkTypedElementLabel); builder.branch(builder.equal(typedElementLabel, otherOwner), checkTypedPushAlloc, failure);
		builder.select(checkTypedPushAlloc); builder.branch(builder.equal(beforeTypedPush, afterTypedPush), checkTypedPushLength, failure);
		builder.select(checkTypedPushLength); builder.branch(builder.equal(typedPushLength, builder.constInt(20)), checkTypedPushValue, failure);
		builder.select(checkTypedPushValue); builder.branch(builder.equal(typedPushValue, builder.constInt(19)), checkTypedPushLabel, failure);
		builder.select(checkTypedPushLabel); builder.branch(builder.equal(typedPushLabel, otherOwner), checkTypedInsertAlloc, failure);
		builder.select(checkTypedInsertAlloc); builder.branch(builder.equal(beforeTypedInsert, afterTypedInsert), checkTypedUnshiftLength, failure);
		builder.select(checkTypedUnshiftLength); builder.branch(builder.equal(typedUnshiftLength, builder.constInt(22)), checkTypedInsertValue, failure);
		builder.select(checkTypedInsertValue); builder.branch(builder.equal(typedInsertValue, builder.constInt(1)), checkTypedInsertLabel, failure);
		builder.select(checkTypedInsertLabel); builder.branch(builder.equal(typedInsertLabel, otherOwner), checkTypedFrontValue, failure);
		builder.select(checkTypedFrontValue); builder.branch(builder.equal(typedFrontValue, builder.constInt(31)), checkTypedFrontLabel, failure);
		builder.select(checkTypedFrontLabel); builder.branch(builder.equal(typedFrontLabel, owner), checkTypedRangesAlloc, failure);
		builder.select(checkTypedRangesAlloc); builder.branch(builder.equal(beforeTypedRanges, afterTypedRanges), checkTypedRangesValidity, failure);
		builder.select(checkTypedRangesValidity); builder.branch(grownInitialized, failure, checkRemovedPairValue);
		builder.select(checkRemovedPairValue); builder.branch(builder.equal(removedPairValue, builder.constInt(1)), checkRemovedPairLabel, failure);
		builder.select(checkRemovedPairLabel); builder.branch(builder.equal(removedPairLabel, otherOwner), checkType, failure);
		builder.select(checkType);
		builder.branch(builder.call("__std_is_exact_type", [builder.toDyn(owner), restoredType], Bool), success, failure);
		builder.select(success); builder.call("std.sys_exit", [builder.constInt(42)], Void); builder.returnValue(builder.constVoid());
		builder.select(failure); builder.call("std.sys_exit", [builder.constInt(1)], Void); builder.returnValue(builder.constVoid());

		var program = new IrProgram("main");
		program.objects = [descriptor, innerDescriptor, ownerDescriptor, pairDescriptor, pairWrapperDescriptor, outerDescriptor, nestedPairDescriptor];
		var callbackBody = new IrBuilder(), callbackInput = callbackBody.argument("array", arrayType), callbackIndex = callbackBody.constInt(0);
		var observed = callbackBody.call(helpers.getter(1), [callbackInput, callbackIndex], I32);
		var sawWrite = callbackBody.createBlock(), missedWrite = callbackBody.createBlock();
		callbackBody.branch(callbackBody.equal(observed, callbackBody.constInt(-258)), sawWrite, missedWrite);
		callbackBody.select(sawWrite);
		callbackBody.call("__value_array_ensure", [callbackInput, callbackBody.constInt(256)], Void);
		callbackBody.call(helpers.setter(1), [callbackInput, callbackIndex, callbackBody.constInt(20)], Void);
		callbackBody.returnValue(callbackBody.constVoid());
		callbackBody.select(missedWrite);
		callbackBody.call(helpers.setter(1), [callbackInput, callbackIndex, callbackBody.constInt(-1000)], Void);
		callbackBody.returnValue(callbackBody.constVoid());
		var nestedBody = new IrBuilder(), nestedInput = nestedBody.argument("array", arrayType), nestedIndex = nestedBody.constInt(0);
		var nestedObserved = nestedBody.call(helpers.getter(nestedSlot), [nestedInput, nestedIndex], I32);
		var nestedSawWrite = nestedBody.createBlock(), nestedMissedWrite = nestedBody.createBlock();
		nestedBody.branch(nestedBody.equal(nestedObserved, nestedBody.constInt(11)), nestedSawWrite, nestedMissedWrite);
		nestedBody.select(nestedSawWrite);
		nestedBody.call("__value_array_ensure", [nestedInput, nestedBody.constInt(1024)], Void);
		nestedBody.call(helpers.setter(nestedSlot), [nestedInput, nestedIndex, nestedBody.constInt(30)], Void);
		nestedBody.returnValue(nestedBody.constVoid());
		nestedBody.select(nestedMissedWrite);
		nestedBody.call(helpers.setter(nestedSlot), [nestedInput, nestedIndex, nestedBody.constInt(-1000)], Void);
		nestedBody.returnValue(nestedBody.constVoid());
		var snapshotBody = new IrBuilder(), snapshotInput = snapshotBody.argument("array", arrayType);
		snapshotBody.call(helpers.setter(nestedSlot), [snapshotInput, snapshotBody.constInt(0), snapshotBody.constInt(50)], Void);
		snapshotBody.returnValue(snapshotBody.constVoid());
		var scalarBody = new IrBuilder(), scalarInput = scalarBody.argument("array", arrayType), scalarIndex = scalarBody.constInt(0);
		scalarBody.call(helpers.setter(5), [scalarInput, scalarIndex, scalarBody.constInt(20)], Void);
		scalarBody.call(helpers.setter(4), [scalarInput, scalarIndex, scalarBody.constBool(true)], Void);
		scalarBody.returnValue(scalarBody.constVoid());
		var compositeBody = new IrBuilder(), compositeInput = compositeBody.argument("array", arrayType), compositeIndex = compositeBody.constInt(0);
		compositeBody.call(helpers.setter(secondValue), [compositeInput, compositeIndex, compositeBody.constInt(120)], Void);
		compositeBody.call(helpers.setter(secondLabel), [compositeInput, compositeIndex, compositeBody.constNull(Obj("LaneOwner"))], Void);
		compositeBody.call(helpers.setter(secondFlag), [compositeInput, compositeIndex, compositeBody.constBool(false)], Void);
		compositeBody.returnValue(compositeBody.constVoid());
		var optionalSnapshotBody = new IrBuilder(), optionalSnapshotInput = optionalSnapshotBody.argument("array", optionalPairArrayType);
		optionalSnapshotBody.call(optionalPairHelpers.setter(optionalPairHelpers.slot(["value"])),
			[optionalSnapshotInput, optionalSnapshotBody.constInt(0), optionalSnapshotBody.constInt(999)], Void);
		optionalSnapshotBody.returnValue(optionalSnapshotBody.constVoid());
		program.functions = [new IrFunction("main", [], Void, builder.blocks), rewrittenMethod, rewrittenThrow, rewrittenNested, rewrittenSnapshot,
			rewrittenOptional, rewrittenScalarSnapshot, rewrittenScalarWrite, rewrittenScalarNull, rewrittenPhiRead, rewrittenPhiWrite,
			rewrittenCopy, rewrittenSelf, rewrittenOptionalCopy, rewrittenConstruct, rewrittenArgument, rewrittenComposite, rewrittenDefaults,
			rewrittenNestedDefaults, rewrittenNestedConstruct, rewrittenNullConstruct, rewrittenPlaceCaller, rewrittenGrowthCaller, rewrittenValueCaller,
			rewrittenOptionalSnapshot, adjustmentFunction,
			new IrFunction("array_place_callback", callbackBody.arguments, Void, callbackBody.blocks),
			new IrFunction("array_place_nested_callback", nestedBody.arguments, Void, nestedBody.blocks),
			new IrFunction("array_place_snapshot_callback", snapshotBody.arguments, Void, snapshotBody.blocks),
			new IrFunction("array_place_scalar_callback", scalarBody.arguments, Void, scalarBody.blocks),
			new IrFunction("array_place_composite_callback", compositeBody.arguments, Void, compositeBody.blocks),
			new IrFunction("array_optional_snapshot_callback", optionalSnapshotBody.arguments, Void, optionalSnapshotBody.blocks)].concat(generatedMethods)
			.concat(helperFunctions).concat(pairBridgeFunctions).concat(pairElementFunctions).concat(pairHelperFunctions)
			.concat(optionalPairBridgeFunctions).concat(optionalPairHelperFunctions).concat(nestedPairBridgeFunctions).concat(nestedPairHelperFunctions)
			.concat(outerBridgeFunctions).concat(outerHelperFunctions);
		program.natives = helpers.natives();
		program.natives.push({name: "__value_array_alloc", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: arrayType});
		program.natives.push({name: "__value_array_alloc_optional_pair", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: optionalPairArrayType});
		program.natives.push({name: "__value_array_alloc_nested_pair", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: nestedPairArrayType});
		program.natives.push({name: "__value_array_alloc_outer", library: "haxeon_runtime", symbol: "__value_array_alloc",
			arguments: [I32, TypeRef, I32, I32, I32, Bool], result: outerArrayType});
		program.natives.push({name: "__value_array_set_bridge_outer", library: "haxeon_runtime", symbol: "__value_array_set_bridge",
			arguments: [outerArrayType, outerReadType, outerWriteType, pairAcceptsType], result: Void});
		program.natives.push({name: "__array_set_any", library: "haxeon_runtime", symbol: "__array_set_any",
			arguments: [Array(Dyn), I32, Dyn], result: Void});
		program.natives.push({name: "__array_get_any", library: "haxeon_runtime", symbol: "__array_get_any",
			arguments: [Array(Dyn), I32], result: Dyn});
		program.natives.push({name: "__array_alloc_ref", library: "haxeon_runtime", symbol: "__array_alloc_ref", arguments: [I32], result: Array(Dyn)});
		program.natives.push({name: "__array_push_any", library: "haxeon_runtime", symbol: "__array_push_any", arguments: [Array(Dyn), Dyn], result: I32});
		program.natives.push({name: "__value_array_mark", library: "haxeon_runtime", symbol: "__value_array_mark",
			arguments: [Array(Dyn), I32], result: Void});
		program.natives.push({name: "__value_array_resize", library: "haxeon_runtime", symbol: "__value_array_resize",
			arguments: [Array(Dyn), I32], result: Void});
		program.natives.push({name: "__value_array_is_initialized", library: "haxeon_runtime", symbol: "__value_array_is_initialized",
			arguments: [Array(Dyn), I32], result: Bool});
		program.natives.push({name: "__value_array_ensure", library: "haxeon_runtime", symbol: "__value_array_ensure",
			arguments: [Array(Dyn), I32], result: Void});
		program.natives.push({name: "__std_is_exact_type", library: "haxeon_runtime", symbol: "__std_is_exact_type",
			arguments: [Dyn, TypeRef], result: Bool});
		for (native in pairFactory.natives()) if (![for (existing in program.natives) existing.name].contains(native.name)) program.natives.push(native);
		program.natives.push({name: "std.gc_total_allocated", library: "std", symbol: "gc_total_allocated", arguments: [], result: F64});
		program.natives.push({name: "std.sys_exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void});
		for (initialized in [false, true]) {
			var missing = new IrBuilder(), missingIndex = missing.constInt(0);
			var missingArray = missing.call("__value_array_alloc", [
				missing.constInt(1), missing.typeValue(element), missing.constInt(shape.scalarStrideBits),
				missing.constInt(shape.references), missing.constInt(shape.scalarWordBits), missing.constBool(true)
			], arrayType);
			if (initialized) missing.call("__value_array_mark", [missingArray, missingIndex], Void);
			missing.call(checkOptional, [missingArray, missingIndex], Void);
			missing.call("std.sys_exit", [missing.constInt(0)], Void);
			missing.returnValue(missing.constVoid());
			program.functions.push(new IrFunction(initialized ? "missing_optional" : "uninitialized", [], Void, missing.blocks));
		}
		for (outOfBounds in [false, true]) {
			var badRead = new IrBuilder(), values = badRead.call(pairFactory.allocateName(), [badRead.constInt(1)], pairArrayType);
			var invalid = badRead.constInt(outOfBounds ? 1 : 0), ignored = new IrValue(800000, "$invalid-element", pairType);
			badRead.currentBlock().instructions.push(new Located(ArrayGet(ignored, values, invalid), SourceProvenance.generated("array-element-test")));
			badRead.call("std.sys_exit", [badRead.constInt(0)], Void);
			badRead.returnValue(badRead.constVoid());
			program.functions.push(new IrFunction(outOfBounds ? "element_out_of_bounds" : "element_uninitialized", [], Void, badRead.blocks));
		}
		var exception = new IrBuilder(), exceptionIndex = exception.constInt(0);
		var exceptionArray = exception.call("__value_array_alloc", [
			exception.constInt(1), exception.typeValue(element), exception.constInt(shape.scalarStrideBits),
			exception.constInt(shape.references), exception.constInt(shape.scalarWordBits), exception.constBool(true)
		], arrayType);
		exception.call(helpers.setter(1), [exceptionArray, exceptionIndex, exception.constInt(20)], Void);
		exception.call("__value_array_mark", [exceptionArray, exceptionIndex], Void);
		var body = exception.createBlock(), handler = exception.createBlock(), after = exception.createBlock(),
			pass = exception.createBlock(), fail = exception.createBlock();
		var start = exception.currentBlock(), provenance = SourceProvenance.generated("array-place-test");
		start.instructions.push(new Located(BeginTry(handler.id, after.id), provenance));
		exception.jump(body);
		exception.select(body);
		exception.call(rewrittenThrow.name, [exceptionArray, exceptionIndex], Void);
		body.instructions.push(new Located(EndTry(handler.id), provenance));
		var notCaught = exception.constBool(false);
		exception.jump(after);
		exception.select(handler);
		handler.instructions.push(new Located(Catch(new IrValue(1000000, "$caught", Dyn)), provenance));
		var caught = exception.constBool(true);
		exception.jump(after);
		exception.select(after);
		var didCatch = exception.phi(Bool, [{block: body.id, value: notCaught}, {block: handler.id, value: caught}]);
		var updated = exception.call(helpers.getter(1), [exceptionArray, exceptionIndex], I32), checkUpdated = exception.createBlock();
		exception.branch(didCatch, checkUpdated, fail);
		exception.select(checkUpdated); exception.branch(exception.equal(updated, exception.constInt(23)), pass, fail);
		exception.select(pass); exception.call("std.sys_exit", [exception.constInt(42)], Void); exception.returnValue(exception.constVoid());
		exception.select(fail); exception.call("std.sys_exit", [exception.constInt(1)], Void); exception.returnValue(exception.constVoid());
		program.functions.push(new IrFunction("method_exception", [], Void, exception.blocks));
		var scalarException = new IrBuilder(), scalarExceptionIndex = scalarException.constInt(0);
		var scalarExceptionArray = scalarException.call("__value_array_alloc", [
			scalarException.constInt(1), scalarException.typeValue(element), scalarException.constInt(shape.scalarStrideBits),
			scalarException.constInt(shape.references), scalarException.constInt(shape.scalarWordBits), scalarException.constBool(true)
		], arrayType);
		scalarException.call("__value_array_mark", [scalarExceptionArray, scalarExceptionIndex], Void);
		var scalarExceptionCallback = scalarException.staticClosure("array_place_scalar_callback", callbackType);
		var scalarBodyBlock = scalarException.createBlock(), scalarHandler = scalarException.createBlock(), scalarAfter = scalarException.createBlock(),
			scalarPass = scalarException.createBlock(), scalarFail = scalarException.createBlock();
		scalarException.currentBlock().instructions.push(new Located(BeginTry(scalarHandler.id, scalarAfter.id), provenance));
		scalarException.jump(scalarBodyBlock);
		scalarException.select(scalarBodyBlock);
		scalarException.call(rewrittenScalarSnapshot.name, [scalarExceptionArray, scalarExceptionIndex, scalarExceptionCallback, scalarExceptionArray], I32);
		scalarBodyBlock.instructions.push(new Located(EndTry(scalarHandler.id), provenance));
		var scalarNotCaught = scalarException.constBool(false);
		scalarException.jump(scalarAfter);
		scalarException.select(scalarHandler);
		scalarHandler.instructions.push(new Located(Catch(new IrValue(1000001, "$caught-scalar", Dyn)), provenance));
		var scalarCaught = scalarException.constBool(true);
		scalarException.jump(scalarAfter);
		scalarException.select(scalarAfter);
		var scalarDidCatch = scalarException.phi(Bool, [{block: scalarBodyBlock.id, value: scalarNotCaught}, {block: scalarHandler.id, value: scalarCaught}]);
		var scalarCurrent = scalarException.call(helpers.getter(5), [scalarExceptionArray, scalarExceptionIndex], I32), scalarCheck = scalarException.createBlock();
		scalarException.branch(scalarDidCatch, scalarCheck, scalarFail);
		scalarException.select(scalarCheck); scalarException.branch(scalarException.equal(scalarCurrent, scalarException.constInt(20)), scalarPass, scalarFail);
		scalarException.select(scalarPass); scalarException.call("std.sys_exit", [scalarException.constInt(42)], Void); scalarException.returnValue(scalarException.constVoid());
		scalarException.select(scalarFail); scalarException.call("std.sys_exit", [scalarException.constInt(1)], Void); scalarException.returnValue(scalarException.constVoid());
		program.functions.push(new IrFunction("scalar_exception", [], Void, scalarException.blocks));
		var optionalStorage = new compiler.ir.IrOptionalFieldStorage(program.objects);
		program.functions = optionalStorage.rewrite(program.functions);
		program.objects = optionalStorage.physicalObjects(program.objects);
		objects = [for (object in program.objects) object.name => object];
		program.functions = new compiler.ir.IrNullableScalarFields(program.objects).rewrite(program.functions);
		program.functions = [for (fn in program.functions) compiler.ir.IrValueArrayOptionalRewrite.rewrite(fn, optionalPairType, optionalPairComponents)];
		program.functions = [for (fn in program.functions) compiler.ir.IrValueArrayElementRewrite.rewrite(fn, pairType, pairElements)];
		compiler.ir.IrScalarArguments.rewrite(program);
		program.functions = [for (fn in program.functions) IrScalarReplacement.rewrite(fn, IrObjectTable.of(objects), false, true)];
		var scalarArgumentCall = false, scalarElementGet = false, scalarElementSet = false, scalarElementPush = false,
			scalarElementInsert = false, scalarElementUnshift = false, escapedPairs = 0;
		for (fn in program.functions) if (fn.name == "main") for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(_, "LanePair"): escapedPairs++;
			case NewObject(_, name) if (name == pairWrapperName): throw "Nullable array mutations must not allocate component wrappers";
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + rewrittenArgument.name): scalarArgumentCall = true;
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + pairElements.getName()): scalarElementGet = true;
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + pairElements.setName()): scalarElementSet = true;
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + pairElements.pushName()): scalarElementPush = true;
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + pairElements.insertName()): scalarElementInsert = true;
			case Call(_, name, _) if (name == compiler.ir.IrScalarArguments.PREFIX + pairElements.unshiftName()): scalarElementUnshift = true;
			default:
		}
		if (escapedPairs != 1) throw "Only the explicit dynamic escape may allocate a pair";
		if (!scalarArgumentCall) throw "Array value arguments must use the scalar call ABI";
		if (!scalarElementGet || !scalarElementSet || !scalarElementPush || !scalarElementInsert || !scalarElementUnshift)
			throw "Typed array element calls must use the scalar call ABI";
		IrVerifier.verify(program);

		var directory = Sys.systemName() == "Linux" ? "/dev/shm" : Sys.getEnv("TMPDIR");
		if (directory == null || directory.length == 0) directory = ".";
		var path = directory + "/haxeon-value-array-access-" + StringTools.replace(Std.string(Sys.time()), ".", "-")
			+ "-" + Std.random(0x7fffffff) + ".hl";
		try {
			var linearFrontend = compiler.Frontend.compile(frontendSource);
			compiler.ir.IrValueArrayProgramRewrite.rewriteAll(linearFrontend, 32, Wasm32);
			compiler.ir.IrValueConstructors.rewrite(linearFrontend);
			compiler.ir.IrValuePhiScalarization.rewrite(linearFrontend);
			var linearTable = IrObjectTable.of([for (object in linearFrontend.objects) object.name => object]);
			linearFrontend.functions = [for (fn in linearFrontend.functions) IrScalarReplacement.rewrite(fn, linearTable, false, true)];
			var linearBytes = new compiler.backend.wasm.WasmBackend().compile(linearFrontend, {target:Wasm32, wasmGcStress:true, debugNames:true}).bytes;
			var linearPath = path + ".linear.wasm";
			try {
				sys.io.File.saveBytes(linearPath, linearBytes);
				var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
					+ 'const result=i.exports.main(); if(result!==15) throw Error("result="+result);';
				var process = new sys.io.Process("node", ["-e", script, linearPath]), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm32 frontend inline array returned $status: $error';
			} catch (error:Dynamic) { if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath); throw error; }
			if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath);
			var multipleArraySource = 'struct MultiA { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'struct MultiB { public var y:Int; public function new(y:Int) this.y=y; } '
				+ 'function main():Int { var a:Array<MultiA>=[new MultiA(10)]; var b:Array<MultiB>=[new MultiB(20)]; '
				+ 'var c:Array<Null<MultiA>>=[null,new MultiA(12)]; var value=c[1]; '
				+ 'return value != null ? a[0].x+b[0].y+value.x : 0; }';
			var nestedScalarSource = 'struct OptionalScalarElement { public var x:Null<Int>; public function new(x:Null<Int>) this.x=x; } '
				+ 'function main():Int { var values:Array<Null<OptionalScalarElement>>=[new OptionalScalarElement(42),null]; '
				+ 'var saved=values[0]; return saved != null && saved.x != null ? saved.x : 0; }';
			for (test in [{source:nullableSource, element:Obj("OptionalParent")},
					{source:nullableElementSource, element:Nullable(Obj("OptionalElement"))},
					{source:nestedScalarSource, element:Nullable(Obj("OptionalScalarElement"))},
					{source:multipleArraySource, element:Obj("MultiA")}]) {
				var linearNullable = compiler.Frontend.compile(test.source);
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(linearNullable, 32, Wasm32);
				compiler.ir.IrValueConstructors.rewrite(linearNullable);
				compiler.ir.IrValuePhiScalarization.rewrite(linearNullable);
				var table = IrObjectTable.of([for (object in linearNullable.objects) object.name => object]);
				linearNullable.functions = [for (fn in linearNullable.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				var bytes = new compiler.backend.wasm.WasmBackend().compile(linearNullable, {target:Wasm32, wasmGcStress:true, debugNames:true}).bytes;
				try {
					sys.io.File.saveBytes(linearPath, bytes);
					var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'const result=i.exports.main(); if(result!==42) throw Error("result="+result);';
					var process = new sys.io.Process("node", ["-e", script, linearPath]), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw 'Wasm32 nullable inline array returned $status: $error';
				} catch (error:Dynamic) { if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath); throw error; }
				if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath);
			}
			compiler.ir.IrValueArrayProgramRewrite.rewriteAll(wasmFrontend, 32, WasmGc);
			compiler.ir.IrValueConstructors.rewrite(wasmFrontend);
			compiler.ir.IrValuePhiScalarization.rewrite(wasmFrontend);
			var wasmTable = IrObjectTable.of([for (object in wasmFrontend.objects) object.name => object]);
			wasmFrontend.functions = [for (fn in wasmFrontend.functions) IrScalarReplacement.rewrite(fn, wasmTable, false, true)];
			var wasmBytes = new compiler.backend.wasm.WasmBackend().compile(wasmFrontend, {target:WasmGc, debugNames:true}).bytes;
			var wasmPath = path + ".wasm";
			try {
				sys.io.File.saveBytes(wasmPath, wasmBytes);
				var script = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
					+ 'const i=new WebAssembly.Instance(m); const result=i.exports.main(); if(result!==15) throw Error("result="+result);';
				var process = new sys.io.Process("node", ["-e", script, wasmPath]), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm GC frontend inline array returned $status: $error';
			} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
			if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			var escapeSource = 'struct EscapeValue { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'function main():Int { var values:Array<EscapeValue> = [new EscapeValue(5)]; var view:Array<Dynamic> = cast values; '
				+ 'var first:EscapeValue = cast view[0]; view[0] = new EscapeValue(9); '
				+ 'var rejected=false; try { view[3] = "wrong"; } catch (error:Dynamic) { rejected=true; } '
				+ 'var rejectedInsert=false; try { view.insert(0, "wrong"); } catch (error:Dynamic) { rejectedInsert=true; } '
				+ 'var intact=values.length == 1 && values[0].x == 9; view.push(new EscapeValue(11)); '
				+ 'view.unshift(new EscapeValue(4)); view.insert(1,new EscapeValue(6)); '
				+ 'view.reverse(); view.reverse(); var snapshot=view.copy(); var removed=view.splice(1,1); '
				+ 'view.resize(5); var nullIndex=view.indexOf(null); var nullRemoved=view.remove(null); view.resize(3); '
				+ 'var joined=view.concat(snapshot); var tail:Array<Dynamic>=["tail"]; var mixed=view.concat(tail); '
				+ 'var fromJoin:EscapeValue=cast joined[4]; var copy=view.copy(); var last:EscapeValue=cast copy.pop(); var firstRemoved:EscapeValue=cast copy.shift(); '
				+ 'var saved:EscapeValue=cast snapshot[1]; var gone:EscapeValue=cast removed[0]; '
				+ 'return first.x == 5 && rejected && rejectedInsert && intact && values.length == 3 && values[0].x == 4 '
				+ '&& values[1].x == 9 && values[2].x == 11 && saved.x == 6 && gone.x == 6 '
				+ '&& nullIndex == 3 && nullRemoved && fromJoin.x == 6 && mixed[3] == "tail" && last.x == 11 && firstRemoved.x == 4 ? 42 : 0; }';
			var mixedEscapeSource = 'class EscapeOwner { public function new() {} } '
				+ 'struct EscapeMixed { public var x:Int; public var owner:EscapeOwner; '
				+ 'public function new(x:Int, owner:EscapeOwner) { this.x=x; this.owner=owner; } } '
				+ 'function main():Int { var owner=new EscapeOwner(); var values:Array<Null<EscapeMixed>>=[null,null]; '
				+ 'var view:Array<Dynamic>=cast values; view[0]=new EscapeMixed(5,owner); view.insert(1,new EscapeMixed(9,owner)); '
				+ 'view.push(null); var saved:Null<EscapeMixed>=cast view[1]; var firstMixed=values[0]; '
				+ 'return saved != null && saved.x == 9 && saved.owner == owner && firstMixed != null && firstMixed.owner == owner '
				+ '&& values[2] == null && values[3] == null ? 42 : 0; }';
			var retypeSource = 'struct RetypedValue { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'function main():Int { var original:Array<Dynamic>=[new RetypedValue(5)]; var alias=original; '
				+ 'var typed:Array<RetypedValue>=cast original; alias[0]=new RetypedValue(9); typed.push(new RetypedValue(12)); '
				+ 'alias.insert(1,new RetypedValue(7)); var sum=0; for (item in alias) { var value:RetypedValue=cast item; sum+=value.x; } '
				+ 'var snapshot=typed.copy(); alias.reverse(); alias.resize(2); var viaAlias:RetypedValue=cast alias[0]; '
				+ 'return typed[0].x == 12 && typed[1].x == 7 && viaAlias.x == 12 && alias.length == 2 '
				+ '&& sum == 28 && snapshot[0].x == 9 && snapshot[2].x == 12 ? 42 : 0; }';
			var rejectedRetypeSource = 'struct RejectedValue { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'function main():Int { var original:Array<Dynamic>=[new RejectedValue(5),"bad"]; var alias=original; var rejected=false; '
				+ 'try { var typed:Array<RejectedValue>=cast original; } catch (error:Dynamic) { rejected=true; } '
				+ 'alias[1]="kept"; var first:RejectedValue=cast original[0]; '
				+ 'return rejected && original.length == 2 && first.x == 5 && original[1] == "kept" ? 42 : 0; }';
			for (test in [{source:retypeSource, element:Obj("RetypedValue"), checked:false},
					{source:retypeSource, element:Obj("RetypedValue"), checked:true},
					{source:rejectedRetypeSource, element:Obj("RejectedValue"), checked:true},
					{source:mixedEscapeSource, element:Nullable(Obj("EscapeMixed")), checked:true},
					{source:escapeSource, element:Obj("EscapeValue"), checked:false},
					{source:escapeSource, element:Obj("EscapeValue"), checked:true}]) {
				var linearDynamic:IrProgram;
				if (test.checked) {
					var file = new compiler.Source.SourceFile("<linear-dynamic-array>", test.source),
						ast = new compiler.syntax.Parser(new compiler.syntax.Lexer(file).tokenize()).parseProgram();
					compiler.ir.IrGenerator.bindNativeArrayChecks(true);
					linearDynamic = compiler.ir.IrGenerator.generate(compiler.types.Typer.type(ast));
					compiler.ir.IrGenerator.bindNativeArrayChecks(false);
				} else linearDynamic = compiler.Frontend.compile(test.source);
				compiler.ir.IrValueArrayProgramRewrite.rewrite(linearDynamic, test.element, 32, Wasm32);
				compiler.ir.IrValueConstructors.rewrite(linearDynamic);
				compiler.ir.IrValuePhiScalarization.rewrite(linearDynamic);
				var table = IrObjectTable.of([for (object in linearDynamic.objects) object.name => object]);
				linearDynamic.functions = [for (fn in linearDynamic.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				var bytes = new compiler.backend.wasm.WasmBackend().compile(linearDynamic, {target:Wasm32, wasmGcStress:true, debugNames:true}).bytes;
				try {
					sys.io.File.saveBytes(linearPath, bytes);
					var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'const result=i.exports.main(); if(result!==42) throw Error("result="+result);';
					var process = new sys.io.Process("node", ["-e", script, linearPath]), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw 'Wasm32 dynamic inline array returned $status: $error';
				} catch (error:Dynamic) { if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath); throw error; }
				if (sys.FileSystem.exists(linearPath)) sys.FileSystem.deleteFile(linearPath);
			}
			for (test in [{source:nullableSource, element:Obj("OptionalParent"), checked:false},
					{source:nullableElementSource, element:Nullable(Obj("OptionalElement")), checked:false},
					{source:nestedScalarSource, element:Nullable(Obj("OptionalScalarElement")), checked:false},
					{source:multipleArraySource, element:Obj("MultiA"), checked:false},
					{source:mixedEscapeSource, element:Nullable(Obj("EscapeMixed")), checked:true},
					{source:retypeSource, element:Obj("RetypedValue"), checked:true},
					{source:retypeSource, element:Obj("RetypedValue"), checked:false},
					{source:rejectedRetypeSource, element:Obj("RejectedValue"), checked:true},
					{source:escapeSource, element:Obj("EscapeValue"), checked:false},
					{source:escapeSource, element:Obj("EscapeValue"), checked:true}]) {
				var nullableWasm:IrProgram;
				if (test.checked) {
					var file = new compiler.Source.SourceFile("<escape-array>", test.source),
						ast = new compiler.syntax.Parser(new compiler.syntax.Lexer(file).tokenize()).parseProgram();
					compiler.ir.IrGenerator.bindNativeArrayChecks(true);
					nullableWasm = compiler.ir.IrGenerator.generate(compiler.types.Typer.type(ast));
					compiler.ir.IrGenerator.bindNativeArrayChecks(false);
				} else nullableWasm = compiler.Frontend.compile(test.source);
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(nullableWasm, 32, WasmGc);
				compiler.ir.IrValueConstructors.rewrite(nullableWasm);
				compiler.ir.IrValuePhiScalarization.rewrite(nullableWasm);
				var table = IrObjectTable.of([for (object in nullableWasm.objects) object.name => object]);
				nullableWasm.functions = [for (fn in nullableWasm.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				var bytes = new compiler.backend.wasm.WasmBackend().compile(nullableWasm, {target:WasmGc, debugNames:true}).bytes;
				try {
					sys.io.File.saveBytes(wasmPath, bytes);
					var script = 'const fs=require("fs"); const m=new WebAssembly.Module(fs.readFileSync(process.argv[1])); '
						+ 'const i=new WebAssembly.Instance(m); const result=i.exports.main(); if(result!==42) throw Error("result="+result);';
					var process = new sys.io.Process("node", ["-e", script, wasmPath]), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw 'Wasm GC nullable inline array returned $status: $error';
				} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
				if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			}
			var rangeSource = 'struct RangePoint { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'class RangeCensus { public static var values:Array<RangePoint>; '
				+ 'public static function prepare(n:Int):Void { values=[]; for (i in 0...n) values.push(new RangePoint(i)); } '
				+ 'public static function perform():Int { var copied=values.copy(); var sliced=values.slice(0,values.length); '
				+ 'var joined=values.concat(values); copied[0].x=77; sliced[0].x=66; joined[0].x=55; '
				+ 'return values[0].x == 0 ? copied[0].x+sliced[0].x+joined[0].x : -1; } } function main():Int return 42;';
			for (target in [Wasm32, WasmGc]) for (inlineEnabled in [false, true]) {
				var rangeProgram = compiler.Frontend.compile(rangeSource);
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(rangeProgram, 32, target);
				for (fn in rangeProgram.functions) for (block in fn.blocks) for (located in block.instructions)
					switch located.provenance.origin {
						case CompilerGenerated(reason) if (reason == compiler.ir.IrGenerator.ArrayValueCopyReason):
							throw 'Boxed copy loop remains in $target lane array IR';
						default:
					}
				compiler.ir.IrValueConstructors.rewrite(rangeProgram);
				compiler.ir.IrValuePhiScalarization.rewrite(rangeProgram);
				compiler.ir.IrScalarArguments.rewrite(rangeProgram, true);
				compiler.ir.IrValuePhiScalarization.rewrite(rangeProgram);
				var table = IrObjectTable.of([for (object in rangeProgram.objects) object.name => object]);
				rangeProgram.functions = [for (fn in rangeProgram.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				compiler.ir.IrNullableScalarFlow.rewrite(rangeProgram);
				compiler.ir.IrInliner.run(rangeProgram, new compiler.ir.IrInliner.IrInlineCache(), inlineEnabled);
				var backendTarget:compiler.backend.Backend.BackendTarget = target == Wasm32 ? Wasm32 : WasmGc;
				var bytes = new compiler.backend.wasm.WasmBackend().compile(rangeProgram, {target:backendTarget, debugNames:true,
					wasmMemoryStats:target == Wasm32, wasmGcAllocationCount:target == WasmGc,
					exports:["RangeCensus.prepare", "RangeCensus.perform"]}).bytes;
				try {
					sys.io.File.saveBytes(wasmPath, bytes);
					var counter = target == Wasm32 ? 'i.exports["haxeon.memory.allocation_count"]()' : 'i.exports.__allocation_count()';
					var script = 'const fs=require("fs"), i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'i.exports.main(); function sample(n) { i.exports["RangeCensus.prepare"](n); const before=$counter; '
						+ 'const value=i.exports["RangeCensus.perform"](), count=$counter-before; if(value!==198) throw Error("result="+value); return count; } '
						+ 'const small=sample(8), large=sample(1024); if(small!==large || large>30) throw Error("small="+small+", large="+large); console.log(large);';
					var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(),
						error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw '$target range allocation census (inline=$inlineEnabled) failed ($status): $error';
					Sys.println('$target copy, slice and concat of 8 or 1024 values (inline=$inlineEnabled): ${StringTools.trim(allocations)} allocations');
				} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
				if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			}
			var censusSource = 'struct CensusPoint { public var x:Int; public function new(x:Int) this.x = x; } '
				+ 'function main():Int { var points:Array<CensusPoint> = []; for (i in 0...100) points.push(new CensusPoint(i)); '
				+ 'var sum = 0; for (point in points) sum += point.x; return sum; }';
			var linearCensus = compiler.Frontend.compile(censusSource);
			compiler.ir.IrValueArrayProgramRewrite.rewrite(linearCensus, Obj("CensusPoint"), 32, Wasm32);
			compiler.ir.IrValueConstructors.rewrite(linearCensus);
			compiler.ir.IrValuePhiScalarization.rewrite(linearCensus);
			var linearCensusTable = IrObjectTable.of([for (object in linearCensus.objects) object.name => object]);
			linearCensus.functions = [for (fn in linearCensus.functions) IrScalarReplacement.rewrite(fn, linearCensusTable, false, true)];
			var linearCensusBytes = new compiler.backend.wasm.WasmBackend().compile(linearCensus, {target:Wasm32, debugNames:true, wasmMemoryStats:true}).bytes;
			try {
				sys.io.File.saveBytes(wasmPath, linearCensusBytes);
				var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
					+ 'const before=i.exports["haxeon.memory.allocation_count"](), result=i.exports.main(), allocations=i.exports["haxeon.memory.allocation_count"]()-before; '
					+ 'if(result!==4950 || allocations>40) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
				var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm32 inline array allocation census failed ($status): $error';
				Sys.println('Wasm32 100-element array allocations: ${StringTools.trim(allocations)}');
			} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
			if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			var census = compiler.Frontend.compile(censusSource);
			compiler.ir.IrValueArrayProgramRewrite.rewrite(census, Obj("CensusPoint"), 32, WasmGc);
			compiler.ir.IrValueConstructors.rewrite(census);
			compiler.ir.IrValuePhiScalarization.rewrite(census);
			var censusTable = IrObjectTable.of([for (object in census.objects) object.name => object]);
			census.functions = [for (fn in census.functions) IrScalarReplacement.rewrite(fn, censusTable, false, true)];
			var censusBytes = new compiler.backend.wasm.WasmBackend().compile(census, {target:WasmGc, debugNames:true, wasmGcAllocationCount:true}).bytes;
			try {
				sys.io.File.saveBytes(wasmPath, censusBytes);
				var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
					+ 'const result=i.exports.main(), allocations=i.exports.__allocation_count(); '
					+ 'if(result!==4950 || allocations>32) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
				var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm GC inline array allocation census failed ($status): $error';
				Sys.println('Wasm GC 100-element array allocations: ${StringTools.trim(allocations)}');
			} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
			if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			var optionalCensusSource = 'class CensusOwner { public function new() {} } '
				+ 'struct CensusOptional { public var x:Int; public var owner:CensusOwner; public function new(x:Int, owner:CensusOwner) { this.x=x; this.owner=owner; } } '
				+ 'function main():Int { var owner = new CensusOwner(); var points:Array<Null<CensusOptional>> = []; '
				+ 'for (i in 0...100) points.push(new CensusOptional(i, owner)); var sum=0; '
				+ 'for (point in points) if (point != null && point.owner == owner) sum += point.x; return sum; }';
			var linearOptionalCensus = compiler.Frontend.compile(optionalCensusSource);
			compiler.ir.IrValueArrayProgramRewrite.rewrite(linearOptionalCensus, Nullable(Obj("CensusOptional")), 32, Wasm32);
			compiler.ir.IrValueConstructors.rewrite(linearOptionalCensus);
			compiler.ir.IrValuePhiScalarization.rewrite(linearOptionalCensus);
			var linearOptionalTable = IrObjectTable.of([for (object in linearOptionalCensus.objects) object.name => object]);
			linearOptionalCensus.functions = [for (fn in linearOptionalCensus.functions) IrScalarReplacement.rewrite(fn, linearOptionalTable, false, true)];
			var linearOptionalBytes = new compiler.backend.wasm.WasmBackend().compile(linearOptionalCensus, {target:Wasm32, debugNames:true, wasmMemoryStats:true}).bytes;
			try {
				sys.io.File.saveBytes(wasmPath, linearOptionalBytes);
				var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
					+ 'const before=i.exports["haxeon.memory.allocation_count"](), result=i.exports.main(), allocations=i.exports["haxeon.memory.allocation_count"]()-before; '
					+ 'if(result!==4950 || allocations>40) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
				var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm32 nullable inline array allocation census failed ($status): $error';
				Sys.println('Wasm32 100-element nullable mixed array allocations: ${StringTools.trim(allocations)}');
			} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
			if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			var optionalCensus = compiler.Frontend.compile(optionalCensusSource);
			compiler.ir.IrValueArrayProgramRewrite.rewrite(optionalCensus, Nullable(Obj("CensusOptional")), 32, WasmGc);
			compiler.ir.IrValueConstructors.rewrite(optionalCensus);
			compiler.ir.IrValuePhiScalarization.rewrite(optionalCensus);
			var optionalCensusTable = IrObjectTable.of([for (object in optionalCensus.objects) object.name => object]);
			optionalCensus.functions = [for (fn in optionalCensus.functions) IrScalarReplacement.rewrite(fn, optionalCensusTable, false, true)];
			var optionalCensusBytes = new compiler.backend.wasm.WasmBackend().compile(optionalCensus, {target:WasmGc, debugNames:true, wasmGcAllocationCount:true}).bytes;
			try {
				sys.io.File.saveBytes(wasmPath, optionalCensusBytes);
				var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
					+ 'const result=i.exports.main(), allocations=i.exports.__allocation_count(); '
					+ 'if(result!==4950 || allocations>40) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
				var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
				process.close();
				if (status != 0) throw 'Wasm GC nullable inline array allocation census failed ($status): $error';
				Sys.println('Wasm GC 100-element nullable mixed array allocations: ${StringTools.trim(allocations)}');
			} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
			if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			var nestedCensusSource = 'struct NestedCensus { public var x:Null<Int>; public function new(x:Null<Int>) this.x=x; } '
				+ 'function main():Int { var values:Array<Null<NestedCensus>>=[]; for(i in 0...100) values.push(new NestedCensus(i)); '
				+ 'var total=0; for(value in values) if(value != null && value.x != null) total += value.x; return total; }';
			var nonoptionalCensusSource = 'struct NestedCensus { public var x:Null<Int>; public function new(x:Null<Int>) this.x=x; } '
				+ 'function main():Int { var values:Array<NestedCensus>=[]; for(i in 0...100) values.push(new NestedCensus(i)); '
				+ 'var total=0; for(value in values) if(value.x != null) total += value.x; return total; }';
			var removalCensusSource = 'struct NestedCensus { public var x:Null<Int>; public function new(x:Null<Int>) this.x=x; } '
				+ 'function main():Int { var values:Array<Null<NestedCensus>>=[]; for(i in 0...100) values.push(new NestedCensus(i)); '
				+ 'var total=0; for(i in 0...100) { var value = i % 2 == 0 ? values.pop() : values.shift(); '
				+ 'if(value != null && value.x != null) total += value.x; } return total; }';
			for (source in [nestedCensusSource, nonoptionalCensusSource, removalCensusSource]) for (target in [Wasm32, WasmGc]) {
				var nestedCensus = compiler.Frontend.compile(source), label = source == nestedCensusSource ? "nullable element" :
					source == nonoptionalCensusSource ? "struct element" : "nullable removals";
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(nestedCensus, 32, target);
				compiler.ir.IrValueConstructors.rewrite(nestedCensus);
				compiler.ir.IrValuePhiScalarization.rewrite(nestedCensus);
				var table = IrObjectTable.of([for (object in nestedCensus.objects) object.name => object]);
				nestedCensus.functions = [for (fn in nestedCensus.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				compiler.ir.IrNullableScalarFlow.rewrite(nestedCensus);
				var backendTarget:compiler.backend.Backend.BackendTarget = target == Wasm32 ? Wasm32 : WasmGc;
				var bytes = new compiler.backend.wasm.WasmBackend().compile(nestedCensus,
					{target:backendTarget, debugNames:true, wasmMemoryStats:target == Wasm32, wasmGcAllocationCount:target == WasmGc}).bytes;
				try {
					sys.io.File.saveBytes(wasmPath, bytes);
					var counter = target == Wasm32 ? 'i.exports["haxeon.memory.allocation_count"]()' : 'i.exports.__allocation_count()';
					var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'const before=$counter, result=i.exports.main(), allocations=$counter-before; '
						+ 'if(result!==4950 || allocations>40) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
					var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw '$target $label nested nullable scalar census failed ($status): $error';
					Sys.println('$target 100 $label nested nullable scalar allocations: ${StringTools.trim(allocations)}');
				} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
				if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			}
			for (source in [nestedCensusSource, nonoptionalCensusSource, removalCensusSource]) {
				var hlCensus = compiler.Frontend.compile(StringTools.replace(source, "return total;", "return total == 4950 ? 42 : 0;"));
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(hlCensus, 64, HashLink);
				compiler.ir.IrValueConstructors.rewrite(hlCensus);
				compiler.ir.IrValuePhiScalarization.rewrite(hlCensus);
				compiler.ir.IrScalarArguments.rewrite(hlCensus);
				compiler.ir.IrValuePhiScalarization.rewrite(hlCensus);
				var table = IrObjectTable.of([for (object in hlCensus.objects) object.name => object]);
				hlCensus.functions = [for (fn in hlCensus.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				compiler.ir.IrNullableScalarFlow.rewrite(hlCensus);
				for (fn in hlCensus.functions) if (fn.name == "main") for (block in fn.blocks) for (located in block.instructions) switch located.value {
					case NewObject(_, "NestedCensus" | "$optional-components:NestedCensus"):
						throw "HashLink array census retains a value box";
					case ToDyn(out, value) if (Type.enumEq(out.type, Nullable(I32)) && value.type == I32):
						throw "HashLink array census retains a nullable scalar box";
					default:
				}
				IrVerifier.verify(hlCensus);
				var hlResult = run(hlCensus, path);
				if (hlResult.status != 42) throw 'HashLink nullable scalar array census returned ${hlResult.status}: ${hlResult.error}';
			}
			var placeCensusSource = 'struct PlaceCensus { public var x:Int; public function new(x:Int) this.x=x; } '
				+ 'function main():Int { var values:Array<Null<PlaceCensus>>=[new PlaceCensus(0)]; '
				+ 'for(i in 0...100) if(values[0]!=null) values[0].x += 1; var result=values[0]; return result==null ? 0 : result.x; }';
			for (target in [Wasm32, WasmGc]) {
				var census = compiler.Frontend.compile(placeCensusSource);
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(census, 32, target);
				compiler.ir.IrValueConstructors.rewrite(census);
				compiler.ir.IrValuePhiScalarization.rewrite(census);
				compiler.ir.IrScalarArguments.rewrite(census, true);
				compiler.ir.IrValuePhiScalarization.rewrite(census);
				var table = IrObjectTable.of([for (object in census.objects) object.name => object]);
				census.functions = [for (fn in census.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				compiler.ir.IrNullableScalarFlow.rewrite(census);
				var backendTarget:compiler.backend.Backend.BackendTarget = target == Wasm32 ? Wasm32 : WasmGc;
				var bytes = new compiler.backend.wasm.WasmBackend().compile(census,
					{target:backendTarget, debugNames:true, wasmMemoryStats:target == Wasm32, wasmGcAllocationCount:target == WasmGc}).bytes;
				try {
					sys.io.File.saveBytes(wasmPath, bytes);
					var counter = target == Wasm32 ? 'i.exports["haxeon.memory.allocation_count"]()' : 'i.exports.__allocation_count()';
					var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'const before=$counter, result=i.exports.main(), allocations=$counter-before; '
						+ 'if(result!==100 || allocations>20) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
					var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw '$target nullable array place census failed ($status): $error';
					Sys.println('$target 100 nullable array place writes: ${StringTools.trim(allocations)} allocations');
				} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
				if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			}
			var equalityCensusSource = 'interface Equatable {} struct CensusKey : Equatable { public var x:Int; public function new(x:Int) this.x=x; '
				+ 'public function equals(other:CensusKey):Bool return x == other.x; } '
				+ 'function main():Int { var values:Array<CensusKey>=[]; for(i in 0...100) values.push(new CensusKey(i)); '
				+ 'var total=0; for(i in 0...100) total += values.indexOf(new CensusKey(i)); return total; }';
			var nullableEqualityCensusSource = StringTools.replace(equalityCensusSource, 'public var x:Int; public function new(x:Int)',
				'public var x:Null<Int>; public function new(x:Null<Int>)');
			for (source in [equalityCensusSource, nullableEqualityCensusSource]) for (target in [Wasm32, WasmGc]) {
				var census = compiler.Frontend.compile(source), label = source == equalityCensusSource ? "scalar" : "nullable scalar";
				compiler.ir.IrValueArrayProgramRewrite.rewriteAll(census, 32, target);
				compiler.ir.IrValueConstructors.rewrite(census);
				compiler.ir.IrValuePhiScalarization.rewrite(census);
				compiler.ir.IrScalarArguments.rewrite(census, true);
				compiler.ir.IrValuePhiScalarization.rewrite(census);
				var table = IrObjectTable.of([for (object in census.objects) object.name => object]);
				census.functions = [for (fn in census.functions) IrScalarReplacement.rewrite(fn, table, false, true)];
				compiler.ir.IrNullableScalarFlow.rewrite(census);
				var backendTarget:compiler.backend.Backend.BackendTarget = target == Wasm32 ? Wasm32 : WasmGc;
				var bytes = new compiler.backend.wasm.WasmBackend().compile(census,
					{target:backendTarget, debugNames:true, wasmMemoryStats:target == Wasm32, wasmGcAllocationCount:target == WasmGc}).bytes;
				try {
					sys.io.File.saveBytes(wasmPath, bytes);
					var counter = target == Wasm32 ? 'i.exports["haxeon.memory.allocation_count"]()' : 'i.exports.__allocation_count()';
					var script = 'const fs=require("fs"); const i=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))); '
						+ 'const before=$counter, result=i.exports.main(), allocations=$counter-before; '
						+ 'if(result!==4950 || allocations>40) throw Error("result="+result+", allocations="+allocations); console.log(allocations);';
					var process = new sys.io.Process("node", ["-e", script, wasmPath]), allocations = process.stdout.readAll().toString(), error = process.stderr.readAll().toString(), status = process.exitCode();
					process.close();
					if (status != 0) throw '$target $label struct array equality census failed ($status): $error';
					Sys.println('$target $label struct array equality allocations: ${StringTools.trim(allocations)}');
				} catch (error:Dynamic) { if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath); throw error; }
				if (sys.FileSystem.exists(wasmPath)) sys.FileSystem.deleteFile(wasmPath);
			}
			var success = run(program, path);
			if (success.status != 42) throw 'Generated inline array access returned ${success.status}: ${success.error}';
			for (frontendProgram in [frontend, typedFrontend]) {
			compiler.ir.IrValueArrayProgramRewrite.rewrite(frontendProgram, Obj("PlaceRoot"), 64, HashLink);
			compiler.ir.IrValueConstructors.rewrite(frontendProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(frontendProgram);
			compiler.ir.IrScalarArguments.rewrite(frontendProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(frontendProgram);
			var frontendTable = IrObjectTable.of([for (object in frontendProgram.objects) object.name => object]);
			frontendProgram.functions = [for (fn in frontendProgram.functions) IrScalarReplacement.rewrite(fn, frontendTable, false, true)];
			for (fn in frontendProgram.functions) if (fn.name == "main" || fn.name == "missingValue") for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case NewObject(_, "PlaceRoot" | "PlaceLeaf"): throw "Frontend array operations must not allocate a struct box";
				case ArrayGet(_, array, _), ArraySet(array, _, _) if (Type.enumEq(array.type, Array(Obj("PlaceRoot")))):
					throw "Frontend array operations must use the inline lanes";
				default:
			}
			IrVerifier.verify(frontendProgram);
			var frontendResult = run(frontendProgram, path);
			if (frontendResult.status != 15) throw 'Frontend inline array returned ${frontendResult.status}: ${frontendResult.error}';
			}
			for (nullableProgram in [nullableFrontend, nullableCheckedFrontend]) {
			compiler.ir.IrValueArrayProgramRewrite.rewrite(nullableProgram, Obj("OptionalParent"), 64, HashLink);
			compiler.ir.IrValueConstructors.rewrite(nullableProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(nullableProgram);
			compiler.ir.IrScalarArguments.rewrite(nullableProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(nullableProgram);
			var nullableTable = IrObjectTable.of([for (object in nullableProgram.objects) object.name => object]);
			nullableProgram.functions = [for (fn in nullableProgram.functions) IrScalarReplacement.rewrite(fn, nullableTable, false, true)];
			for (fn in nullableProgram.functions) if (fn.name == "main") for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case NewObject(_, "OptionalParent" | "OptionalChild"): throw "Nullable nested array values must stay scalar";
				default:
			}
			IrVerifier.verify(nullableProgram);
			var nullableResult = run(nullableProgram, path);
			if (nullableResult.status != 42) throw 'Nullable frontend inline array returned ${nullableResult.status}: ${nullableResult.error}';
			}
			var nullableElementType:IrType = Nullable(Obj("OptionalElement"));
			for (nullableElementProgram in [nullableElementFrontend, nullableElementChecked]) {
			compiler.ir.IrValueArrayProgramRewrite.rewrite(nullableElementProgram, nullableElementType, 64, HashLink);
			compiler.ir.IrValueConstructors.rewrite(nullableElementProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(nullableElementProgram);
			compiler.ir.IrScalarArguments.rewrite(nullableElementProgram);
			compiler.ir.IrValuePhiScalarization.rewrite(nullableElementProgram);
			var nullableElementTable = IrObjectTable.of([for (object in nullableElementProgram.objects) object.name => object]);
			nullableElementProgram.functions = [for (fn in nullableElementProgram.functions) IrScalarReplacement.rewrite(fn, nullableElementTable, false, true)];
			for (fn in nullableElementProgram.functions) if (fn.name == "main") for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case NewObject(_, "OptionalElement" | "$optional-components:OptionalElement"):
					throw "Nullable array elements must stay scalar";
				case Call(_, name, _) if (name == compiler.ir.IrOptionalValueFlow.boxName("OptionalElement")
						|| name == compiler.ir.IrOptionalValueFlow.unboxName("OptionalElement")):
					throw "Nullable array elements must not cross a boxed boundary";
				case Call(_, "__array_get_any" | "__array_set_any" | "__array_copy_any" | "__array_slice_any" | "__array_concat_any"
						| "__array_splice_any" | "__array_resize_any" | "__array_reverse_any" | "__array_splice_ref" | "__array_resize_ref" | "__array_reverse_ref"
						| "__array_push_any" | "__array_unshift_any" | "__array_insert_any" | "__array_push_ref" | "__array_unshift_ref" | "__array_insert_ref", args) if (args.length > 0
						&& Type.enumEq(args[0].type, Array(nullableElementType))):
					throw "Typed nullable arrays must not use dynamic access";
				case ArrayGet(_, array, _), ArraySet(array, _, _) if (Type.enumEq(array.type, Array(nullableElementType))):
					throw "Nullable array elements must use component lanes";
				default:
			}
			IrVerifier.verify(nullableElementProgram);
			var nullableElementResult = run(nullableElementProgram, path);
			if (nullableElementResult.status != 42) throw 'Nullable element array returned ${nullableElementResult.status}: ${nullableElementResult.error}';
			}
			program.entryPoint = "method_exception";
			var exceptionResult = run(program, path);
			if (exceptionResult.status != 42) throw 'Array place exception returned ${exceptionResult.status}: ${exceptionResult.error}';
			program.entryPoint = "scalar_exception";
			var scalarExceptionResult = run(program, path);
			if (scalarExceptionResult.status != 42)
				throw 'Nullable scalar snapshot exception returned ${scalarExceptionResult.status}: ${scalarExceptionResult.error}';
			for (entry in ["uninitialized", "missing_optional"]) {
				program.entryPoint = entry;
				var failure = run(program, path);
				if (failure.status == 0 || failure.error.indexOf("Null access") < 0)
					throw 'Value array check $entry returned ${failure.status}: ${failure.error}';
			}
			for (entry in ["element_uninitialized", "element_out_of_bounds"]) {
				program.entryPoint = entry;
				var failure = run(program, path), expected = entry == "element_uninitialized" ? "Null access" : "Array index out of bounds";
				if (failure.status == 0 || failure.error.indexOf(expected) < 0)
					throw 'Value array read $entry returned ${failure.status}: ${failure.error}';
			}
		} catch (error:Dynamic) {
			if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println("PASS: array places preserve writes, snapshots, growth and exceptions without allocating value boxes");
	}

	static function run(program:IrProgram, path:String):{status:Int, error:String} {
		HlWriter.writeFile(HlLower.lower(program), path);
		var process = new sys.io.Process(Sys.getCwd() + "/.tools/hashlink/hl", [path]);
		var error = process.stderr.readAll().toString();
		var status = process.exitCode();
		process.close();
		return {status: status, error: error};
	}
}
