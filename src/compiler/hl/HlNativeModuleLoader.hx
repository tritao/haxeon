package compiler.hl;

import haxe.io.Bytes;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import compiler.hl.patch.HlPatchReader;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlFunctionVersionTable.HlFunctionVersionEntry;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataTypeAppend;
import runtime.hashlink.HlNativeModule;
import runtime.hashlink.HlRuntimePatchCode;
import runtime.hashlink.HlRuntimeModule;
import runtime.hashlink.HlRuntimePatchPublication;
import runtime.memory.RawPtr;

/** Owns the HLB model, Haxe metadata, and native module for one loaded module. */
class HlLoadedNativeModule {
	public final module:HlModule;
	public final code:HlCode;
	public final metadata:HlMetadataGeneration;
	public final nativeModule:HlNativeModule;

	var disposed:Bool = false;

	function new(module:HlModule, metadata:HlMetadataGeneration, nativeModule:HlNativeModule) {
		this.module = module;
		this.code = module.code;
		this.metadata = metadata;
		this.nativeModule = nativeModule;
	}

	/** Retire the native module and then release its Haxe-owned metadata arena. */
	public function unload():Bool {
		if (disposed)
			return true;
		if (!nativeModule.unload())
			return false;
		metadata.dispose();
		disposed = true;
		return true;
	}

	/** Invoke a zero-argument i32 function while the loaded module is live. */
	public function callI32(functionIndex:Int):Int {
		if (disposed)
			throw "HashLink loaded module has been unloaded";
		return nativeModule.callI32(functionIndex);
	}

	/** Require both native and Haxe-owned resources to be released. */
	public function close():Void {
		if (!unload())
			throw "HashLink loaded module could not be unloaded";
	}
}

/** Owns one Haxe-built metadata generation loaded by the runtime wrapper. */
class HlLoadedRuntimeModule {
	public final module:HlModule;
	public final code:HlCode;
	public final identity:HlRuntimeManifest;
	public final metadata:HlMetadataGeneration;
	public final nativeModule:HlRuntimeModule;

	final patchState:HlRuntimePatchState;

	public var functions(get, never):HlFunctionVersionTable;
	public var revision(get, never):Int;

	var disposed:Bool = false;
	var borrowers:Int = 0;

	function new(module:HlModule, identity:HlRuntimeManifest, metadata:HlMetadataGeneration, nativeModule:HlRuntimeModule, functions:HlFunctionVersionTable) {
		this.module = module;
		this.code = module.code;
		this.identity = identity;
		this.metadata = metadata;
		this.nativeModule = nativeModule;
		patchState = new HlRuntimePatchState(identity.revision, functions);
	}

	function get_functions():HlFunctionVersionTable
		return patchState.functions;

	function get_revision():Int
		return patchState.revision;

	/** Retire the runtime wrapper and then release its Haxe-owned metadata arena. */
	public function unload():Bool {
		if (disposed)
			return true;
		if (borrowers != 0)
			return false;
		if (!nativeModule.unload())
			return false;
		patchState.releaseAll();
		metadata.dispose();
		disposed = true;
		return true;
	}

	/** Whether the Haxe-owned runtime module is still available for calls. */
	public inline function isLoaded():Bool
		return !disposed && nativeModule.isLoaded();

	/** Number of Haxe-side borrowers that currently protect this module. */
	public inline function borrowerCount():Int
		return borrowers;

	/** Borrow this module until the returned lease is released. */
	public function acquire():HlRuntimeModuleLease {
		if (!isLoaded())
			throw "HashLink loaded runtime module has been unloaded";
		borrowers++;
		return new HlRuntimeModuleLease(this);
	}

	/** Invoke a stable zero-argument i32 function while the loaded module is live. */
	public function callI32(stableId:Int):Int {
		if (disposed)
			throw "HashLink loaded runtime module has been unloaded";
		if (!HlRuntimeCallPolicy.validFunction(module, identity, stableId, 0))
			throw 'Invalid Haxe-built runtime i32 call (stable ID $stableId)';
		return nativeModule.callI32(stableId);
	}

	/** Invoke a Haxe-owned zero-argument void function. */
	public function callVoid(stableId:Int):Void {
		if (disposed)
			throw "HashLink loaded runtime module has been unloaded";
		if (!HlRuntimeCallPolicy.validFunction(module, identity, stableId, 1))
			throw 'Invalid Haxe-built runtime void call (stable ID $stableId)';
		nativeModule.callVoid(stableId);
	}

	/** Stage an external HLP update under Haxe-owned revision state. */
	public function stagePatch(bytes:Bytes):HlRuntimePatchTransaction {
		if (disposed)
			throw "HashLink loaded runtime module has been unloaded";
		return new HlRuntimePatchTransaction(this, bytes);
	}

	/** Apply an external HLP update through the Haxe-owned transaction policy. */
	public function patch(bytes:Bytes):Void {
		if (disposed)
			throw "HashLink loaded runtime module has been unloaded";
		new HlRuntimePatchTransaction(this, bytes).commit();
	}

	/** Return the committed Haxe-owned patch models in revision order. */
	public function committedPatches():Array<HlPatch>
		return patchState.ledger.patches();

	/** Return committed patch generations with function versions and dependencies. */
	public function committedPatchGenerations():Array<HlRuntimePatchGeneration>
		return patchState.ledger.snapshots();

	/** Number of committed generations whose replaced functions are all superseded. */
	public var retiredPatchCount(get, never):Int;

	function get_retiredPatchCount():Int
		return patchState.ledger.retiredCount;

	/** Return retired patch generations as isolated diagnostic snapshots. */
	public function retiredPatchGenerations():Array<HlRuntimePatchGeneration>
		return patchState.ledger.retiredSnapshots();

	/** Return the native revision retained by one committed patch generation. */
	public function committedPatchCodeRevision(index:Int):Int {
		return patchState.ledger.codeRevision(index);
	}

	/** Haxeon preflights the decoded HLP model before native publication. */
	@:allow(compiler.hl.HlRuntimePatchTransaction)
	function commitPatch(bytes:Bytes, ?decoded:HlPatchEnvelope, ?decodedModel:HlPatch):Void {
		var patch:HlPatchEnvelope = decoded;
		var model:HlPatch = decodedModel;
		if (patch == null)
			try {
				model = HlPatchReader.decode(bytes);
				patch = model.envelope();
			} catch (error:Dynamic) {
				throw 'Haxeon rejected the HLP patch: ${Std.string(error)}';
			}
		if (model == null)
			try {
				model = HlPatchReader.decode(bytes);
			} catch (error:Dynamic) {
				throw 'Haxeon rejected the HLP patch: ${Std.string(error)}';
			}
		if (patch.moduleId.compare(identity.moduleId) != 0)
			throw "Haxeon rejected an HLP patch for another module";
		if (patch.baseRevision != revision)
			throw 'Haxeon rejected a stale HLP patch (expected revision $revision, got ${patch.baseRevision})';
		validatePatchPolicy(patch, model);
		var nextFunctions = patchState.advance(patch.functionStableIds, patch.revision),
			typeAppend = HlNativeMetadataBuilder.preparePatchTypes(module, metadata, model),
			publication:HlRuntimePatchPublication;
		try {
			var patchPools = HlNativeMetadataBuilder.preparePatchPools(module, metadata, model);
			var patchFunctions = HlNativeMetadataBuilder.preparePatchFunctions(metadata, model, identity);
			var patchDebug = HlNativeMetadataBuilder.preparePatchDebug(metadata, model);
			publication = nativeModule.patchCodeWithHaxeMetadata(bytes, model.types.length, patchFunctions, patchPools, patchDebug);
		} catch (error:Dynamic) {
			typeAppend.rollback();
			throw error;
		}
		if (publication.status != 0) {
			typeAppend.rollback();
			if (!nativeModule.releaseCode(publication.code))
				throw "HashLink rejected the Haxe-built runtime patch and leaked its code handle";
			throw 'HashLink rejected the Haxe-built runtime patch (status ${publication.status})';
		}
		var patchCode:HlRuntimePatchCode;
		try {
			patchCode = new HlRuntimePatchCode(nativeModule, publication);
		} catch (error:Dynamic) {
			if (!nativeModule.releaseCode(publication.code))
				throw "HashLink accepted the Haxe-built runtime patch but leaked its code handle";
			typeAppend.rollback();
			throw error;
		}
		typeAppend.commit();
		applyPatchSymbols(model);
		patchState.publish(model, patch, nextFunctions, patchCode);
	}

	/** Validate HLP identity and live bytecode compatibility before staging. */
	@:allow(compiler.hl.HlRuntimePatchTransaction)
	function validatePatchPolicy(patch:HlPatchEnvelope, model:HlPatch):Void {
		HlPatchPolicy.validate(module, identity, revision, patch, model);
	}

	/** Advance the Haxe-owned symbol model only after native publication succeeds. */
	function applyPatchSymbols(model:HlPatch):Void {
		for (value in model.ints)
			module.code.ints.push(value);
		for (value in model.floats)
			module.code.floats.push(value);
		for (value in model.strings)
			module.code.strings.push(value);
		for (type in model.types)
			module.code.types.push(type);
	}

	/** Execute the manifest initializer through the Haxe-owned runtime policy. */
	@:allow(compiler.hl.HlNativeModuleLoader)
	function initialize():Void {
		if (identity.initializerSlot < 0)
			return;
		for (entry in identity.entries)
			if (entry.functionIndex == identity.initializerSlot) {
				if (!HlRuntimeCallPolicy.validFunction(module, identity, entry.stableId, 1))
					throw "HLI initializer must reference a zero-argument void function";
				callVoid(entry.stableId);
				return;
			}
		throw "HLI initializer slot is not represented by the identity table";
	}

	@:allow(compiler.hl.HlRuntimeModuleLease)
	function releaseBorrow():Void {
		if (borrowers == 0)
			throw "HashLink loaded runtime module lease count is already zero";
		borrowers--;
	}
}

/** Borrowed view that keeps one Haxe-built runtime module from retirement. */
class HlRuntimeModuleLease {
	public final module:HlLoadedRuntimeModule;

	var released:Bool = false;

	@:allow(compiler.hl.HlLoadedRuntimeModule)
	function new(module:HlLoadedRuntimeModule) {
		this.module = module;
	}

	/** Release this borrow. Repeated release is safe. */
	public function release():Void {
		if (released)
			return;
		released = true;
		module.releaseBorrow();
	}

	public inline function isReleased():Bool
		return released;
}

/** Loads HLB through Haxe policy before handing the resulting record to HashLink. */
class HlNativeModuleLoader {
	public static function load(bytes:Bytes, ?functionPointers:Array<RawPtr<UInt8>>, ?flags:Int = 0):HlLoadedNativeModule {
		var module = HlModule.decode(bytes),
			metadata = HlNativeMetadataBuilder.buildModule(module, functionPointers);
		try {
			return new HlLoadedNativeModule(module, metadata, new HlNativeModule(metadata, flags));
		} catch (error:Dynamic) {
			metadata.dispose();
			throw error;
		}
	}

	/** Build Haxe-owned metadata, then hand its complete code record to HashLink. */
	public static function loadRuntime(bytes:Bytes, identity:Bytes):HlLoadedRuntimeModule {
		var module = HlModule.decode(bytes),
			identityModel = validateIdentity(HlRuntimeIdentity.decode(identity), module),
			metadata = HlNativeMetadataBuilder.buildModule(module);
		var loaded:Null<HlLoadedRuntimeModule> = null;
		try {
			var functions = functionVersions(module, identityModel, metadata);
			loaded = new HlLoadedRuntimeModule(module, identityModel, metadata,
				new HlRuntimeModule(metadata, bytes, identityModel.moduleId, identityModel.revision, [for (entry in identityModel.entries) entry.stableId],
					[for (entry in identityModel.entries) entry.functionIndex], identityModel.initializerSlot),
				functions);
			loaded.initialize();
			return loaded;
		} catch (error:Dynamic) {
			if (loaded == null)
				metadata.dispose();
			else if (!loaded.unload())
				throw "HashLink external runtime module could not be unloaded after initialization failure";
			throw error;
		}
	}

	static function validateIdentity(identity:HlRuntimeManifest, model:HlModule):HlRuntimeManifest {
		var initializerEntry = identity.initializerSlot < 0;
		for (entry in identity.entries)
			if (model.functionAt(entry.functionIndex) == null)
				throw 'HLI identity references missing dispatch slot ${entry.functionIndex}';
			else if (entry.functionIndex == identity.initializerSlot)
				initializerEntry = true;
		if (!initializerEntry)
			throw 'HLI initializer references a slot absent from the identity table';
		return identity;
	}

	static function functionVersions(module:HlModule, identity:HlRuntimeManifest, metadata:HlMetadataGeneration):HlFunctionVersionTable {
		var entries:Array<HlFunctionVersionEntry> = [];
		for (entry in identity.entries) {
			var fn = module.functionAt(entry.functionIndex);
			if (fn == null)
				throw 'HLI identity references missing bytecode function ${entry.functionIndex}';
			entries.push({
				stableId: entry.stableId,
				slot: entry.functionIndex,
				typeIndex: fn.type,
				entrypoint: metadata.functionPointer(entry.functionIndex)
			});
		}
		return new HlFunctionVersionTable(entries, identity.revision);
	}
}
