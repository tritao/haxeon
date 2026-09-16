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
		functions: HlFunctionVersionTable.fromMetadata(metadata, [stableId])
	};
}

function buildNativeGeneration(stableId:Int):BuiltHotReloadGeneration {
	var built = buildGeneration(false, false, stableId),
		metadata = built.metadata,
		intType = metadata.type(0),
		functionType = metadata.type(2),
		registers = metadata.arena.allocTypePointerArray(1),
		ops = metadata.arena.allocOpcodeArray(1);
	registers.store(intType);
	ops.ref.op = 67;
	ops.ref.p1 = 0;
	ops.ref.p2 = 0;
	ops.ref.p3 = 0;
	ops.ref.extra = RawPtr.nullPtr();
	metadata.addFunctionDescriptor({
		findex: 0,
		nregs: 1,
		nops: 1,
		reference: 0,
		nassigns: 0,
		type: functionType,
		regs: registers,
		ops: ops,
		debug: RawPtr.nullPtr(),
		assigns: RawPtr.nullPtr(),
		object: RawPtr.nullPtr(),
		fieldName: RawPtr.nullPtr(),
		fieldReference: RawPtr.nullPtr()
	});
	metadata.defineFunctionIdentities([stableId], ["Native.main"]);
	return built;
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
	var versionProbe = new HlFunctionVersionTable([
		{
			stableId: 1,
			slot: 0,
			typeIndex: 0,
			entrypoint: RawPtr.nullPtr()
		},
		{
			stableId: 2,
			slot: 1,
			typeIndex: 0,
			entrypoint: RawPtr.nullPtr()
		}
	],
		1), advancedVersionProbe = versionProbe.advance([1],
			2), generationPolicy = advancedVersionProbe.at(1).generation == 2
			&& advancedVersionProbe.at(2)
				.generation == 1, state = new HlHotReloadState(), initial = buildGeneration(false,
			false), initialTransaction = state.stage(initial.metadata,
			initial.functions), initialGeneration = initialTransaction.commit(), initialLease = state.currentLease(), append = buildGeneration(false,
			true), appendTransaction = state.stage(append.metadata,
			append.functions), appendGeneration = appendTransaction.commit(), appendCompatible = isCompatible(appendTransaction.decision)
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
	var retiredAcquireRejected = false;
	try
		initialGeneration.acquire()
	catch (error:Dynamic)
		retiredAcquireRejected = true;

	var metadataOnlyLease = advanceGeneration.metadata.acquire(),
		metadataDisposeBlocked = false;
	try
		state.dispose()
	catch (error:Dynamic)
		metadataDisposeBlocked = true;
	metadataOnlyLease.release();
	var reopenedLease = state.currentLease(),
		reopenedAfterMetadataFailure = !reopenedLease.isReleased();
	reopenedLease.release();
	var currentLease = state.currentLease(), disposeBlocked = false;
	try
		state.dispose()
	catch (error:Dynamic)
		disposeBlocked = true;
	currentLease.release();
	state.dispose();
	var nativeState = new HlHotReloadState(),
		nativeInitial = buildNativeGeneration(31),
		nativeInitialTransaction = nativeState.stage(nativeInitial.metadata, nativeInitial.functions),
		nativeInitialGeneration = nativeInitialTransaction.commitNative(),
		nativeInitialLoaded = nativeInitialGeneration.nativeModule != null && nativeInitialGeneration.nativeModule.isLoaded(),
		nativeNext = buildNativeGeneration(31),
		nativeNextTransaction = nativeState.stage(nativeNext.metadata, nativeNext.functions),
		nativeNextGeneration = nativeNextTransaction.commitNative(),
		nativeDispatchStable = nativeState.nativeDispatchModule() == nativeInitialGeneration.nativeModule,
		nativeRetired = nativeState.retiredCount == 1 && nativeState.disposeRetired() == 0 && nativeState.retiredCount == 1,
		nativeCurrentLoaded = nativeNextGeneration.nativeModule != null
			&& nativeNextGeneration.nativeModule.isLoaded()
			&& nativeState.nativeDispatchModule() != null
			&& nativeState.nativeDispatchModule().isLoaded();
	nativeState.dispose();
	return generationPolicy && appendCompatible && signatureRejected && reloadWorked && patchWorked && signatureReplacementRejected && identityRejected
		&& transactionState && retiredBorrowed && disposedBeforeRelease && released && retiredAcquireRejected && metadataDisposeBlocked
		&& reopenedAfterMetadataFailure && disposeBlocked && nativeInitialLoaded && nativeDispatchStable && nativeRetired && nativeCurrentLoaded ? 42 : 1;
}
