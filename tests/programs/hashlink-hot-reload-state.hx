import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlMetadataCompatibility;
import runtime.hashlink.HlHotReloadState;
import runtime.hashlink.HlHotReloadState.HlHotReloadDecision;
import runtime.hashlink.HlHotReloadTransaction;
import runtime.hashlink.HlHotReloadTransaction.HlHotReloadTransactionState;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlTypeKind;
import runtime.memory.RawPtr;

typedef BuiltHotReloadGeneration = {
	final metadata:HlMetadataGeneration;
	final functions:HlFunctionVersionTable;
}

function buildGeneration(changed:Bool, extraType:Bool, stableId:Int = 7):BuiltHotReloadGeneration {
	var metadata = new HlMetadataGeneration(128, 1),
		intType = metadata.builder.primitive(HlTypeKind.Int32Type),
		floatType = metadata.builder.primitive(HlTypeKind.Float32Type),
		argument = changed ? floatType : intType,
		functionType = metadata.builder.functionType([argument], intType);
	metadata.addType(intType);
	metadata.addType(floatType);
	metadata.addType(functionType);
	if (extraType)
		metadata.addType(metadata.builder.primitive(HlTypeKind.BoolType));
	metadata.defineModule([RawPtr.nullPtr()], [functionType]);
	return {
		metadata: metadata,
		functions: new HlFunctionVersionTable([
			{
				stableId: stableId,
				slot: 0,
				typeIndex: 2,
				entrypoint: RawPtr.nullPtr()
			}
		])
	};
}

function isCompatible(decision:HlHotReloadDecision):Bool
	return switch decision {
		case Compatible:
			true;
		case RequiresReload(_):
			false;
	};

function requiresReload(decision:HlHotReloadDecision):Bool
	return !isCompatible(decision);

function main():Int {
	var state = new HlHotReloadState(),
		initial = buildGeneration(false, false),
		initialTransaction = state.stage(initial.metadata, initial.functions),
		initialGeneration = initialTransaction.commit(),
		initialLease = state.currentLease(),
		append = buildGeneration(false, true),
		appendTransaction = state.stage(append.metadata, append.functions),
		appendGeneration = appendTransaction.commit(),
		appendCompatible = isCompatible(appendTransaction.decision)
			&& appendGeneration.revision == 2
			&& appendGeneration.functions.at(7).generation == 2
			&& state.retiredCount == 1;

	var signatureChange = buildGeneration(true, true),
		signatureTransaction = state.stage(signatureChange.metadata, signatureChange.functions),
		normalCommitRejected = false;
	try
		signatureTransaction.commit()
	catch (error:Dynamic)
		normalCommitRejected = true;
	var signatureRejected = requiresReload(signatureTransaction.decision) && normalCommitRejected && state.revision == 2;
	signatureTransaction.rollback();

	var reload = buildGeneration(true, true),
		reloadTransaction = state.stage(reload.metadata, reload.functions, true),
		reloaded = reloadTransaction.commit(),
		reloadWorked = requiresReload(reloadTransaction.decision)
			&& reloadTransaction.state == HlHotReloadTransactionState.Committed
			&& reloaded.revision == 3
			&& state.retiredCount == 2;

	var patch = buildGeneration(true, true),
		replacementPointer:RawPtr<UInt8> = patch.metadata.arena.allocNativePointerArray(1).castTo(),
		patchFunctions = reloaded.functions.replace([
			{
				stableId: 7,
				typeIndex: 2,
				entrypoint: replacementPointer
			}
		],
			state.revision + 1),
		patchTransaction = state.stage(patch.metadata, patchFunctions),
		patched = patchTransaction.commit(),
		patchWorked = isCompatible(patchTransaction.decision)
			&& patched.revision == 4
			&& patched.functions.at(7).entrypoint == replacementPointer
			&& patched.functions.at(7).generation == 4;
	var signatureReplacementRejected = false;
	try
		reloaded.functions.replace([{stableId: 7, typeIndex: 1, entrypoint: RawPtr.nullPtr()}], state.revision + 1)
	catch (error:Dynamic)
		signatureReplacementRejected = true;

	var wrongIdentity = buildGeneration(true, true, 8),
		wrongIdentityDecision = state.compatibility(wrongIdentity.metadata, wrongIdentity.functions),
		identityRejected = requiresReload(wrongIdentityDecision);
	wrongIdentity.metadata.dispose();

	var staleCandidate = buildGeneration(true, true),
		stale = state.stage(staleCandidate.metadata, staleCandidate.functions),
		advanceCandidate = buildGeneration(true, true),
		advance = state.stage(advanceCandidate.metadata, advanceCandidate.functions),
		advanceGeneration = advance.commit(),
		staleRejected = false;
	try
		stale.commit()
	catch (error:Dynamic)
		staleRejected = true;
	stale.rollback();
	var transactionState = advanceGeneration.revision == 5
		&& staleRejected
		&& stale.state == HlHotReloadTransactionState.RolledBack
		&& advance.state == HlHotReloadTransactionState.Committed;

	var retiredBorrowed = state.retiredBorrowedCount == 1,
		disposedBeforeRelease = state.disposeRetired() == 3 && state.retiredCount == 1;
	initialLease.release();
	var released = initialLease.isReleased() && state.retiredBorrowedCount == 0 && state.disposeRetired() == 1 && state.retiredCount == 0;

	var currentLease = state.currentLease(), disposeBlocked = false;
	try
		state.dispose()
	catch (error:Dynamic)
		disposeBlocked = true;
	currentLease.release();
	state.dispose();
	return appendCompatible && signatureRejected && reloadWorked && patchWorked && signatureReplacementRejected && identityRejected && transactionState
		&& retiredBorrowed && disposedBeforeRelease && released && disposeBlocked ? 42 : 1;
}
