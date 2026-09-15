import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataRegistry;
import runtime.hashlink.HlMetadataCompatibility;
import runtime.hashlink.HlMetadataCompatibility.HlMetadataDecision;
import runtime.hashlink.HlTypeKind;
import runtime.hashlink.HlMetadataTransaction;
import runtime.hashlink.HlMetadataTransaction.HlMetadataTransactionState;
import runtime.hashlink.HlTypeArena;
import runtime.memory.RawPtr;
import haxe.io.Bytes;

function buildPrimitiveGeneration(extra:Bool):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		type = generation.builder.primitive(HlTypeKind.Int32Type);
	generation.addType(type);
	if (extra)
		generation.addType(generation.builder.primitive(HlTypeKind.Float32Type));
	generation.defineModule([RawPtr.nullPtr()], [type]);
	return generation;
}

function buildFunctionGeneration(changed:Bool):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		intType = generation.builder.primitive(HlTypeKind.Int32Type),
		floatType = generation.builder.primitive(HlTypeKind.Float32Type),
		argument = changed ? floatType : intType,
		functionType = generation.builder.functionType([argument], intType);
	generation.addType(intType);
	generation.addType(floatType);
	generation.addType(functionType);
	generation.defineModule([RawPtr.nullPtr()], [functionType]);
	return generation;
}

function buildGlobalGeneration(kind:HlTypeKind, count:Int):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		type = generation.builder.primitive(kind);
	generation.addType(type);
	generation.defineModule([RawPtr.nullPtr()], [type]);
	generation.defineGlobalTypes([for (_ in 0...count) type]);
	return generation;
}

function buildObjectGeneration(fieldKind:HlTypeKind):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		intType = generation.builder.primitive(HlTypeKind.Int32Type),
		floatType = generation.builder.primitive(HlTypeKind.Float32Type),
		fieldType = fieldKind == HlTypeKind.Int32Type ? intType : floatType,
		module = generation.defineModule([RawPtr.nullPtr()], [intType]),
		object = generation.builder.objectType(generation.builder.utf16Name("ReloadObject"), RawPtr.nullPtr(), [
			{
				name: generation.builder.utf16Name("value"),
				type: fieldType,
				hashedName: 17
			}
		], [], [], RawPtr.nullPtr(), module, RawPtr.nullPtr());
	generation.addType(intType);
	generation.addType(floatType);
	generation.addType(object);
	return generation;
}

function buildConstantGeneration(field:Int):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		type = generation.builder.primitive(HlTypeKind.Int32Type),
		fields = generation.arena.allocInt32Array(1);
	fields.store(cast field);
	generation.addType(type);
	generation.defineModule([RawPtr.nullPtr()], [type]);
	generation.defineGlobalTypes([type]);
	generation.addConstant({global: 0, nfields: 1, fields: fields});
	return generation;
}

function buildModuleGeneration(ints:Array<Int>, floats:Array<Float>, strings:Array<String>, bytes:String, debug:String):HlMetadataGeneration {
	var generation = new HlMetadataGeneration(128, 1),
		type = generation.builder.primitive(HlTypeKind.Int32Type),
		byteData = Bytes.ofString(bytes);
	generation.addType(type);
	generation.defineModule([RawPtr.nullPtr()], [type]);
	generation.defineModulePools(new runtime.hashlink.HlModulePools(generation.arena, generation.builder, ints, floats, strings, byteData,
		byteData.length == 0 ? [] : [0], 0));
	if (debug != null)
		generation.addDebugSection({
			kind: 1,
			version: 1,
			flags: 0,
			payload: Bytes.ofString(debug)
		});
	return generation;
}

function isCompatible(decision:HlMetadataDecision):Bool
	return switch decision {
		case Compatible:
			true;
		case RequiresReload(_):
			false;
	};

function requiresReload(decision:HlMetadataDecision):Bool
	return switch decision {
		case Compatible:
			false;
		case RequiresReload(_):
			true;
	};

function cString(arena:HlTypeArena, value:String):RawPtr<UInt8> {
	var result = arena.allocUInt8Array(value.length + 1);
	for (index in 0...value.length)
		result.offset(index).store(cast value.charCodeAt(index));
	result.offset(value.length).store(cast 0);
	return result;
}

function main():Int {
	var registry = new HlMetadataRegistry(),
		first = buildPrimitiveGeneration(false),
		firstPublication = registry.publish(first),
		firstType = firstPublication.types.offset(0).load(),
		firstLease = registry.currentLease(),
		second = buildPrimitiveGeneration(true),
		appendDecision = registry.compatibility(second),
		secondPublication = registry.publish(second),
		current = registry.currentPublication();
	var switched = isCompatible(appendDecision)
		&& registry.revision == 2
		&& registry.retiredCount == 1
		&& current.moduleContext == secondPublication.moduleContext
		&& current.types.offset(0).load() != firstType
		&& first.type(0) == firstType;
	var structural = buildObjectGeneration(HlTypeKind.Float32Type),
		structuralDecision = registry.compatibility(structural),
		normalPublishRejected = false;
	try
		registry.publish(structural)
	catch (error:Dynamic)
		normalPublishRejected = true;
	var rejectionStable = normalPublishRejected && registry.revision == 2 && registry.retiredCount == 1,
		structuralPublication = registry.reload(structural),
		reloaded = requiresReload(structuralDecision)
			&& registry.revision == 3
			&& registry.retiredCount == 2
			&& structuralPublication.types.offset(2).load() == structural.type(2);
	var globalBefore = buildGlobalGeneration(HlTypeKind.Int32Type, 0),
		globalAfter = buildGlobalGeneration(HlTypeKind.Int32Type, 1),
		globalShapeChanged = requiresReload(HlMetadataCompatibility.check(globalBefore, globalAfter));
	globalBefore.dispose();
	globalAfter.dispose();
	var globalTypeBefore = buildGlobalGeneration(HlTypeKind.Int32Type, 1),
		globalTypeAfter = buildGlobalGeneration(HlTypeKind.Float32Type, 1),
		globalTypeChanged = requiresReload(HlMetadataCompatibility.check(globalTypeBefore, globalTypeAfter));
	globalTypeBefore.dispose();
	globalTypeAfter.dispose();
	var objectBefore = buildObjectGeneration(HlTypeKind.Int32Type),
		objectAfter = buildObjectGeneration(HlTypeKind.Float32Type),
		objectChanged = requiresReload(HlMetadataCompatibility.check(objectBefore, objectAfter));
	objectBefore.dispose();
	objectAfter.dispose();
	var nativeBefore = buildPrimitiveGeneration(false),
		nativeAfter = buildPrimitiveGeneration(false),
		nativeChangedAfter = buildPrimitiveGeneration(false);
	nativeBefore.addNativeDescriptor({
		library: cString(nativeBefore.arena, "lib"),
		name: cString(nativeBefore.arena, "bind"),
		type: nativeBefore.type(0),
		findex: 0
	});
	nativeAfter.addNativeDescriptor({
		library: cString(nativeAfter.arena, "lib"),
		name: cString(nativeAfter.arena, "bind"),
		type: nativeAfter.type(0),
		findex: 0
	});
	nativeChangedAfter.addNativeDescriptor({
		library: cString(nativeChangedAfter.arena, "lib"),
		name: cString(nativeChangedAfter.arena, "changed"),
		type: nativeChangedAfter.type(0),
		findex: 0
	});
	var nativeNamesMatch = isCompatible(HlMetadataCompatibility.check(nativeBefore, nativeAfter));
	var nativeChanged = requiresReload(HlMetadataCompatibility.check(nativeBefore, nativeChangedAfter));
	nativeBefore.dispose();
	nativeAfter.dispose();
	nativeChangedAfter.dispose();
	var functionBefore = buildFunctionGeneration(false),
		functionAfter = buildFunctionGeneration(true),
		functionChanged = requiresReload(HlMetadataCompatibility.check(functionBefore, functionAfter));
	var derivedFunction = functionBefore.type(2).ref.data.ref.fun;
	derivedFunction.ref.closureType.ref.kind = cast HlTypeKind.Function;
	derivedFunction.ref.closure.ref.args = derivedFunction.ref.args;
	derivedFunction.ref.closure.ref.ret = derivedFunction.ref.ret;
	derivedFunction.ref.closure.ref.nargs = derivedFunction.ref.nargs;
	var equivalentFunction = buildFunctionGeneration(false),
		derivedStateIgnored = isCompatible(HlMetadataCompatibility.check(functionBefore, equivalentFunction));
	functionBefore.dispose();
	functionAfter.dispose();
	equivalentFunction.dispose();
	var constantBefore = buildConstantGeneration(0),
		constantAfter = buildConstantGeneration(1),
		constantChanged = requiresReload(HlMetadataCompatibility.check(constantBefore, constantAfter));
	constantBefore.dispose();
	constantAfter.dispose();
	var poolBefore = buildModuleGeneration([1], [1.5], ["one"], "xyz", null),
		poolAppend = buildModuleGeneration([1, 2], [1.5], ["one", "two"], "xyz", null),
		poolChanged = buildModuleGeneration([9], [1.5], ["one"], "xyz", null),
		poolBytesChanged = buildModuleGeneration([1], [1.5], ["one"], "changed", null),
		poolAppendCompatible = isCompatible(HlMetadataCompatibility.check(poolBefore, poolAppend)),
		poolChangedRequiresReload = requiresReload(HlMetadataCompatibility.check(poolBefore, poolChanged)),
		poolBytesRequireReload = requiresReload(HlMetadataCompatibility.check(poolBefore, poolBytesChanged));
	poolBefore.dispose();
	poolAppend.dispose();
	poolChanged.dispose();
	poolBytesChanged.dispose();
	var debugBefore = buildModuleGeneration([], [], [], "", "old"),
		debugSame = buildModuleGeneration([], [], [], "", "old"),
		debugChanged = buildModuleGeneration([], [], [], "", "new"),
		debugStable = isCompatible(HlMetadataCompatibility.check(debugBefore, debugSame)),
		debugRequiresReload = requiresReload(HlMetadataCompatibility.check(debugBefore, debugChanged));
	debugBefore.dispose();
	debugSame.dispose();
	debugChanged.dispose();
	var reloadCandidate = buildObjectGeneration(HlTypeKind.Int32Type),
		reloadTransaction = new HlMetadataTransaction(registry, reloadCandidate, true);
	var reloadPublication = reloadTransaction.commit();
	var transactionReloaded = requiresReload(reloadTransaction.decision)
		&& reloadTransaction.state == HlMetadataTransactionState.Committed
		&& registry.revision == 4
		&& reloadPublication.types.offset(2).load() == reloadCandidate.type(2);
	var retiredBorrowedBefore = registry.retiredBorrowedCount;
	var retiredDisposedCount = registry.disposeRetired();
	var retiredCountAfter = registry.retiredCount;
	var reloadRetiredDisposed = retiredBorrowedBefore == 1 && retiredDisposedCount == 2 && retiredCountAfter == 1;
	firstLease.release();
	var releasedRetiredDisposed = firstLease.isReleased();
	releasedRetiredDisposed = releasedRetiredDisposed && registry.retiredBorrowedCount == 0;
	var releasedDisposedCount = registry.disposeRetired();
	releasedRetiredDisposed = releasedRetiredDisposed && releasedDisposedCount == 1 && registry.retiredCount == 0;
	var disposed = releasedRetiredDisposed, firstReleased = false;
	try
		first.type(0)
	catch (error:Dynamic)
		firstReleased = true;
	var transactionRegistry = new HlMetadataRegistry(),
		transaction = new HlMetadataTransaction(transactionRegistry, buildPrimitiveGeneration(false)),
		staleTransaction = new HlMetadataTransaction(transactionRegistry, buildPrimitiveGeneration(false));
	transaction.commit();
	var staleRejected = false;
	try
		staleTransaction.commit()
	catch (error:Dynamic)
		staleRejected = true;
	staleTransaction.rollback();
	var transactionStates = transaction.state == HlMetadataTransactionState.Committed
		&& staleRejected
		&& staleTransaction.state == HlMetadataTransactionState.RolledBack;
	var currentLease = transactionRegistry.currentLease(),
		disposeBlocked = false;
	try
		transactionRegistry.dispose()
	catch (error:Dynamic)
		disposeBlocked = true;
	currentLease.release();
	transactionRegistry.dispose();
	registry.dispose();
	return switched && rejectionStable && reloaded && globalShapeChanged && globalTypeChanged && disposed && firstReleased && objectChanged
		&& constantChanged && nativeNamesMatch && nativeChanged && functionChanged && derivedStateIgnored && transactionReloaded && reloadRetiredDisposed
		&& releasedRetiredDisposed && transactionStates && disposeBlocked && poolAppendCompatible && poolChangedRequiresReload && poolBytesRequireReload
		&& debugStable && debugRequiresReload ? 42 : 1;
}
