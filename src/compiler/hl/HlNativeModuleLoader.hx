package compiler.hl;

import haxe.io.Bytes;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import compiler.hl.patch.HlPatchHashes;
import compiler.hl.patch.HlPatchReader;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlFunctionVersionTable.HlFunctionVersionEntry;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlNativeModule;
import runtime.hashlink.HlRuntimeModule;
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
	public var functions(default, null):HlFunctionVersionTable;
	public var revision(default, null):Int;

	final patchLedger:Array<HlPatch> = [];

	var disposed:Bool = false;
	var borrowers:Int = 0;

	function new(module:HlModule, identity:HlRuntimeManifest, metadata:HlMetadataGeneration, nativeModule:HlRuntimeModule, functions:HlFunctionVersionTable) {
		this.module = module;
		this.code = module.code;
		this.identity = identity;
		this.metadata = metadata;
		this.nativeModule = nativeModule;
		this.functions = functions;
		revision = identity.revision;
	}

	/** Retire the runtime wrapper and then release its Haxe-owned metadata arena. */
	public function unload():Bool {
		if (disposed)
			return true;
		if (borrowers != 0)
			return false;
		if (!nativeModule.unload())
			return false;
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
		return patchLedger.copy();

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
		var nextFunctions = functions.advance(patch.functionStableIds, patch.revision);
		var status = nativeModule.patch(bytes);
		if (status != 0)
			throw 'HashLink rejected the Haxe-built runtime patch (status $status)';
		applyPatchSymbols(model);
		patchLedger.push(model);
		functions = nextFunctions;
		revision = patch.revision;
	}

	/** Validate HLP identity and live bytecode compatibility before staging. */
	@:allow(compiler.hl.HlRuntimePatchTransaction)
	function validatePatchPolicy(patch:HlPatchEnvelope, model:HlPatch):Void {
		validatePatchBases(patch, model);
		validatePatchDebugFiles(model);
		for (stableId in patch.functionStableIds) {
			if (!hasFunctionIdentity(stableId))
				throw 'Haxeon rejected an HLP patch for unknown function identity $stableId';
		}
		for (stableId in patch.relocationStableIds)
			if (!hasFunctionIdentity(stableId))
				throw 'Haxeon rejected an HLP relocation for unknown function identity $stableId';
		var totalTypes = model.baseTypes + model.types.length;
		for (fn in model.functions) {
			var slot = identitySlot(fn.functionIndex);
			if (slot < 0)
				throw 'Haxeon rejected an HLP patch for unknown function identity ${fn.functionIndex}';
			if (fn.slot != slot)
				throw 'Haxeon rejected function identity ${fn.functionIndex} for dispatch slot ${fn.slot} (expected $slot)';
			var live = module.functionAt(fn.slot);
			if (live == null)
				throw 'Haxeon rejected a patch for missing bytecode slot ${fn.slot}';
			if (fn.type != live.type)
				throw 'Haxeon rejected a signature change for function identity ${fn.functionIndex}';
			for (registerType in fn.registers)
				if (registerType < 0 || registerType >= totalTypes)
					throw 'Haxeon rejected an invalid register type $registerType for function identity ${fn.functionIndex}';
			for (relocation in fn.relocations)
				if (relocation.instruction < 0 || relocation.instruction >= fn.instructions.length)
					throw 'Haxeon rejected an out-of-range relocation instruction ${relocation.instruction} for function identity ${fn.functionIndex}';
		}
	}

	function validatePatchBases(patch:HlPatchEnvelope, model:HlPatch):Void {
		if (patch.baseRevision == revision
			&& (model.baseInts != module.code.ints.length
				|| model.baseFloats != module.code.floats.length
				|| model.baseStrings != module.code.strings.length
				|| model.baseTypes != module.code.types.length))
			throw "Haxeon rejected an HLP patch with stale symbol bases";
		if (patch.baseRevision == revision
			&& (model.intPrefixHash != HlPatchHashes.ints(module.code.ints, model.baseInts)
				|| model.floatPrefixHash != HlPatchHashes.floats(module.code.floats, model.baseFloats)
				|| model.stringPrefixHash != HlPatchHashes.strings(module.code.strings, model.baseStrings)
				|| model.typePrefixHash != HlPatchHashes.types(module.code.types, model.baseTypes)))
			throw "Haxeon rejected an HLP patch with stale symbol prefix hashes";
		validatePatchTypes(model);
		validatePatchInstructions(model, model.baseTypes
			+ model.types.length, model.baseInts
			+ model.ints.length, model.baseFloats
			+ model.floats.length,
			model.baseStrings
			+ model.strings.length);
	}

	function validatePatchDebugFiles(model:HlPatch):Void {
		for (path in model.debugFiles)
			if (!hasDebugFile(path))
				throw 'Haxeon rejected a patch debug file absent from the loaded module: $path';
	}

	function hasDebugFile(path:String):Bool {
		var hasDebug = false;
		for (fn in module.code.functions)
			if (fn.debugLocations.length > 0)
				hasDebug = true;
		if (!hasDebug)
			return false;
		for (fn in module.code.functions) {
			if (fn.debugLocations.length == 0) {
				if (path == "<generated>")
					return true;
				continue;
			}
			for (location in fn.debugLocations)
				if (location.path == path)
					return true;
		}
		return false;
	}

	function validatePatchTypes(model:HlPatch):Void {
		var totalTypes = model.baseTypes + model.types.length,
			totalStrings = model.baseStrings + model.strings.length;
		for (type in model.types)
			switch type {
				case Function(arguments, result):
					for (argument in arguments)
						validatePatchTypeIndex(argument, totalTypes);
					validatePatchTypeIndex(result, totalTypes);
				case Abstract(name):
					if (name < 0 || name >= totalStrings)
						throw 'Haxeon rejected an appended abstract name index $name';
				case Parameterized(_, parameter):
					validatePatchTypeIndex(parameter, totalTypes);
				case Simple(_):
				case Method(_, _), Object(_, _, _, _, _, _), Structure(_, _, _, _, _), Virtual(_), Enum(_, _, _):
					throw "Haxeon rejected an unsupported appended HLP type";
			}
	}

	function validatePatchTypeIndex(index:Int, totalTypes:Int):Void {
		if (index < 0 || index >= totalTypes)
			throw 'Haxeon rejected an appended type reference $index';
	}

	function validatePatchInstructions(model:HlPatch, totalTypes:Int, totalInts:Int, totalFloats:Int, totalStrings:Int):Void {
		for (fn in model.functions) {
			var trapTargets:Array<Int> = [];
			for (index in 0...fn.instructions.length) {
				while (trapTargets.length > 0 && trapTargets[trapTargets.length - 1] == index)
					trapTargets.pop();
				var instruction = fn.instructions[index],
					operands = instruction.operands;
				HlOpcodeSchema.validate(instruction.opcode, operands);
				switch instruction.opcode {
					case HlOpcode.Label:
					case HlOpcode.Mov:
						requireRegisters(fn, operands, 0, 2, "move");
					case HlOpcode.Int:
						requireRegister(fn, operands[0], "integer destination");
						requireSymbol(operands[1], totalInts, "integer");
					case HlOpcode.Float:
						requireRegister(fn, operands[0], "float destination");
						requireSymbol(operands[1], totalFloats, "float");
					case HlOpcode.String:
						requireRegister(fn, operands[0], "string destination");
						requireSymbol(operands[1], totalStrings, "string");
					case HlOpcode.Bool:
						requireRegister(fn, operands[0], "boolean destination");
						if (operands[1] != 0 && operands[1] != 1)
							throw 'Haxeon rejected an invalid boolean literal in function identity ${fn.functionIndex}';
					case HlOpcode.Add | HlOpcode.Sub | HlOpcode.Mul | HlOpcode.SDiv | HlOpcode.UDiv | HlOpcode.SMod | HlOpcode.UMod | HlOpcode.Shl | HlOpcode.SShr | HlOpcode.UShr | HlOpcode.And | HlOpcode.Or | HlOpcode.Xor:
						requireRegisters(fn, operands, 0, 3, "arithmetic");
					case HlOpcode.Call0 | HlOpcode.Call1 | HlOpcode.Call2 | HlOpcode.Call3 | HlOpcode.Call4:
						requireRegister(fn, operands[0], "call destination");
						requireFunctionTarget(operands[1], "call");
						requireRegisters(fn, operands, 2, operands.length - 2, "call argument");
					case HlOpcode.CallN:
						requireRegister(fn, operands[0], "variadic call destination");
						requireFunctionTarget(operands[1], "variadic call");
						requireArgumentCount(operands, "variadic call");
						requireRegisters(fn, operands, 3, operands.length - 3, "variadic call argument");
					case HlOpcode.CallMethod | HlOpcode.CallThis:
						requireRegister(fn, operands[0], "method call destination");
						requireNonNegative(operands[1], "method call target");
						requireArgumentCount(operands, "method call");
						requireRegisters(fn, operands, 3, operands.length - 3, "method call argument");
					case HlOpcode.CallClosure:
						requireRegisters(fn, operands, 0, 2, "closure call");
						requireNonNegative(operands[2], "closure argument count");
						if (operands[2] != operands.length - 3)
							throw 'Haxeon rejected a mismatched closure argument count in function identity ${fn.functionIndex}';
						requireRegisters(fn, operands, 3, operands.length - 3, "closure call argument");
					case HlOpcode.StaticClosure:
						requireRegister(fn, operands[0], "static closure destination");
						requireFunctionTarget(operands[1], "static closure");
					case HlOpcode.InstanceClosure:
						requireRegister(fn, operands[0], "instance closure destination");
						requireFunctionTarget(operands[1], "instance closure");
						requireRegister(fn, operands[2], "instance closure receiver");
					case HlOpcode.Field:
						requireRegisters(fn, operands, 0, 2, "field read");
						requireNonNegative(operands[2], "field index");
					case HlOpcode.SetField:
						requireRegister(fn, operands[0], "field write object");
						requireNonNegative(operands[1], "field index");
						requireRegister(fn, operands[2], "field write source");
					case HlOpcode.GetArray:
						requireRegisters(fn, operands, 0, 3, "array read");
					case HlOpcode.SetArray:
						requireRegisters(fn, operands, 0, 3, "array write");
					case HlOpcode.ArraySize:
						requireRegisters(fn, operands, 0, 2, "array size");
					case HlOpcode.New:
						requireRegister(fn, operands[0], "object allocation");
					case HlOpcode.MakeEnum:
						requireRegister(fn, operands[0], "enum destination");
						requireNonNegative(operands[1], "enum constructor");
						requireArgumentCount(operands, "enum construction");
						requireRegisters(fn, operands, 3, operands.length - 3, "enum argument");
					case HlOpcode.EnumAlloc | HlOpcode.EnumIndex:
						requireRegisters(fn, operands, 0, 2, "enum operation");
					case HlOpcode.EnumField:
						requireRegisters(fn, operands, 0, 2, "enum field");
						requireNonNegative(operands[2], "enum constructor");
						requireNonNegative(operands[3], "enum field");
					case HlOpcode.Type:
						requireRegister(fn, operands[0], "type destination");
						requireSymbol(operands[1], totalTypes, "type");
					case HlOpcode.GetGlobal:
						requireRegister(fn, operands[0], "global read destination");
						requireSymbol(operands[1], module.code.globals.length, "global");
					case HlOpcode.SetGlobal:
						requireSymbol(operands[0], module.code.globals.length, "global");
						requireRegister(fn, operands[1], "global write source");
					case HlOpcode.Null | HlOpcode.GetThis | HlOpcode.SetThis | HlOpcode.ToDyn | HlOpcode.ToSFloat | HlOpcode.ToUFloat | HlOpcode.ToInt | HlOpcode.SafeCast | HlOpcode.UnsafeCast | HlOpcode.ToVirtual:
						requireRegister(fn, operands[0], "unary destination");
						if (operands.length > 1)
							requireRegister(fn, operands[1], "unary source");
					case HlOpcode.JTrue:
						requireRegister(fn, operands[0], "conditional branch");
						requireBranch(index, operands[1], fn.instructions.length, "conditional branch");
					case HlOpcode.JSLt | HlOpcode.JSLte | HlOpcode.JEq:
						requireRegisters(fn, operands, 0, 2, "comparison branch");
						requireBranch(index, operands[2], fn.instructions.length, "comparison branch");
					case HlOpcode.JAlways:
						requireBranch(index, operands[0], fn.instructions.length, "branch");
					case HlOpcode.Ret:
						requireRegister(fn, operands[0], "return");
					case HlOpcode.Throw | HlOpcode.Rethrow:
						requireRegister(fn, operands[0], "throw");
					case HlOpcode.Trap:
						requireRegister(fn, operands[0], "trap destination");
						requireBranch(index, operands[1], fn.instructions.length, "trap");
						if (operands[1] < 0 || trapTargets.length == 256)
							throw 'Haxeon rejected invalid trap nesting in function identity ${fn.functionIndex}';
						trapTargets.push(index + 1 + operands[1]);
					case HlOpcode.EndTrap:
						requireRegister(fn, operands[0], "end-trap destination");
						if (trapTargets.length == 0)
							throw 'Haxeon rejected an unmatched end-trap in function identity ${fn.functionIndex}';
						trapTargets.pop();
					default:
						throw 'Haxeon rejected unsupported patch opcode ${instruction.opcode} for function identity ${fn.functionIndex}';
				}
			}
			if (trapTargets.length != 0)
				throw 'Haxeon rejected unbalanced patch traps for function identity ${fn.functionIndex}';
		}
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

	function requireRegister(fn:compiler.hl.patch.HlPatch.HlPatchFunction, index:Int, kind:String):Void {
		if (index < 0 || index >= fn.registers.length)
			throw 'Haxeon rejected an invalid $kind register in function identity ${fn.functionIndex}';
	}

	function requireRegisters(fn:compiler.hl.patch.HlPatch.HlPatchFunction, operands:Array<Int>, start:Int, count:Int, kind:String):Void {
		for (index in start...start + count)
			requireRegister(fn, operands[index], kind);
	}

	function requireSymbol(index:Int, count:Int, kind:String):Void {
		if (index < 0 || index >= count)
			throw 'Haxeon rejected an invalid $kind symbol index $index';
	}

	function requireNonNegative(value:Int, kind:String):Void {
		if (value < 0)
			throw 'Haxeon rejected a negative $kind';
	}

	function requireFunctionTarget(index:Int, kind:String):Void {
		if (module.functionAt(index) == null && module.nativeAt(index) == null)
			throw 'Haxeon rejected an invalid $kind target $index';
	}

	function requireArgumentCount(operands:Array<Int>, kind:String):Void {
		requireNonNegative(operands[2], "$kind argument count");
		if (operands[2] != operands.length - 3)
			throw 'Haxeon rejected a mismatched $kind argument count';
	}

	function requireBranch(index:Int, offset:Int, instructionCount:Int, kind:String):Void {
		var target = index + 1 + offset;
		if (target < 0 || target >= instructionCount)
			throw 'Haxeon rejected an invalid $kind target $target';
	}

	function hasFunctionIdentity(stableId:Int):Bool {
		for (entry in identity.entries)
			if (entry.stableId == stableId)
				return true;
		return false;
	}

	function identitySlot(stableId:Int):Int {
		for (entry in identity.entries)
			if (entry.stableId == stableId)
				return entry.functionIndex;
		return -1;
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
