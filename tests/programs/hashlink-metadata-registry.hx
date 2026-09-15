import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataRegistry;
import runtime.hashlink.HlMetadataCompatibility;
import runtime.hashlink.HlMetadataCompatibility.HlMetadataDecision;
import runtime.hashlink.HlTypeKind;
import runtime.hashlink.HlMetadataTransaction;
import runtime.hashlink.HlMetadataTransaction.HlMetadataTransactionState;
import runtime.memory.RawPtr;

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

function main():Int {
	var registry = new HlMetadataRegistry(),
		first = buildPrimitiveGeneration(false),
		firstPublication = registry.publish(first),
		firstType = firstPublication.types.offset(0).load(),
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
			&& structuralPublication.types.offset(2).load() == structural.type(2),
		disposed = registry.disposeRetired() == 2 && registry.retiredCount == 0,
		firstReleased = false;
	try
		first.type(0)
	catch (error:Dynamic)
		firstReleased = true;
	var objectBefore = buildObjectGeneration(HlTypeKind.Int32Type),
		objectAfter = buildObjectGeneration(HlTypeKind.Float32Type),
		objectChanged = requiresReload(HlMetadataCompatibility.check(objectBefore, objectAfter));
	objectBefore.dispose();
	objectAfter.dispose();
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
	var reloadCandidate = buildObjectGeneration(HlTypeKind.Int32Type),
		reloadTransaction = new HlMetadataTransaction(registry, reloadCandidate, true),
		reloadPublication = reloadTransaction.commit(),
		transactionReloaded = requiresReload(reloadTransaction.decision)
			&& reloadTransaction.state == HlMetadataTransactionState.Committed
			&& registry.revision == 4
			&& reloadPublication.types.offset(2).load() == reloadCandidate.type(2),
		reloadRetiredDisposed = registry.disposeRetired() == 1 && registry.retiredCount == 0;
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
	transactionRegistry.dispose();
	registry.dispose();
	return switched && rejectionStable && reloaded && disposed && firstReleased && objectChanged && functionChanged && derivedStateIgnored
		&& transactionReloaded && reloadRetiredDisposed && transactionStates ? 42 : 1;
}
