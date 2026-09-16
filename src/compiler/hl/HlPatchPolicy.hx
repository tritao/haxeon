package compiler.hl;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import compiler.hl.patch.HlPatch.HlPatchFunction;
import compiler.hl.patch.HlPatchHashes;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;

/** Shared Haxe-owned compatibility policy for external and host HLP paths. */
class HlPatchPolicy {
	public static function validate(module:HlModule, identity:HlRuntimeManifest, revision:Int, patch:HlPatchEnvelope, model:HlPatch):Void {
		if (module == null || identity == null || patch == null || model == null)
			throw "Haxeon HLP policy requires a module, identity, envelope, and model";
		validatePatchBases(module, revision, patch, model);
		validatePatchDebugFiles(module, model);
		for (stableId in patch.functionStableIds)
			if (!hasFunctionIdentity(identity, stableId))
				throw 'Haxeon rejected an HLP patch for unknown function identity $stableId';
		for (stableId in patch.relocationStableIds)
			if (!hasFunctionIdentity(identity, stableId))
				throw 'Haxeon rejected an HLP relocation for unknown function identity $stableId';
		var totalTypes = model.baseTypes + model.types.length;
		for (fn in model.functions) {
			var slot = identitySlot(identity, fn.functionIndex);
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

	static function validatePatchBases(module:HlModule, revision:Int, patch:HlPatchEnvelope, model:HlPatch):Void {
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
		validatePatchInstructions(module, model, model.baseTypes
			+ model.types.length, model.baseInts
			+ model.ints.length,
			model.baseFloats
			+ model.floats.length, model.baseStrings
			+ model.strings.length);
	}

	static function validatePatchDebugFiles(module:HlModule, model:HlPatch):Void {
		for (path in model.debugFiles)
			if (!hasDebugFile(module, path))
				throw 'Haxeon rejected a patch debug file absent from the loaded module: $path';
	}

	static function hasDebugFile(module:HlModule, path:String):Bool {
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

	static function validatePatchTypes(model:HlPatch):Void {
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

	static function validatePatchTypeIndex(index:Int, totalTypes:Int):Void {
		if (index < 0 || index >= totalTypes)
			throw 'Haxeon rejected an appended type reference $index';
	}

	static function validatePatchInstructions(module:HlModule, model:HlPatch, totalTypes:Int, totalInts:Int, totalFloats:Int, totalStrings:Int):Void {
		for (fn in model.functions) {
			var trapTargets:Array<Int> = [];
			for (index in 0...fn.instructions.length) {
				while (trapTargets.length > 0 && trapTargets[trapTargets.length - 1] == index)
					trapTargets.pop();
				var instruction = fn.instructions[index],
					operands = instruction.operands;
				HlOpcodeSchema.validate(instruction.opcode, operands);
				validatePatchInstruction(module, fn, index, instruction.opcode, operands, totalTypes, totalInts, totalFloats, totalStrings, trapTargets);
			}
			if (trapTargets.length != 0)
				throw 'Haxeon rejected unbalanced patch traps for function identity ${fn.functionIndex}';
		}
	}

	static function validatePatchInstruction(module:HlModule, fn:HlPatchFunction, index:Int, opcode:Int, operands:Array<Int>, totalTypes:Int, totalInts:Int,
			totalFloats:Int, totalStrings:Int, trapTargets:Array<Int>):Void {
		switch opcode {
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
				requireFunctionTarget(module, operands[1], "call");
				requireRegisters(fn, operands, 2, operands.length - 2, "call argument");
			case HlOpcode.CallN:
				requireRegister(fn, operands[0], "variadic call destination");
				requireFunctionTarget(module, operands[1], "variadic call");
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
				requireFunctionTarget(module, operands[1], "static closure");
			case HlOpcode.InstanceClosure:
				requireRegister(fn, operands[0], "instance closure destination");
				requireFunctionTarget(module, operands[1], "instance closure");
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
				throw 'Haxeon rejected unsupported patch opcode ${opcode} for function identity ${fn.functionIndex}';
		}
	}

	static function requireRegister(fn:HlPatchFunction, index:Int, kind:String):Void {
		if (index < 0 || index >= fn.registers.length)
			throw 'Haxeon rejected an invalid $kind register in function identity ${fn.functionIndex}';
	}

	static function requireRegisters(fn:HlPatchFunction, operands:Array<Int>, start:Int, count:Int, kind:String):Void {
		for (index in start...start + count)
			requireRegister(fn, operands[index], kind);
	}

	static function requireSymbol(index:Int, count:Int, kind:String):Void {
		if (index < 0 || index >= count)
			throw 'Haxeon rejected an invalid $kind symbol index $index';
	}

	static function requireNonNegative(value:Int, kind:String):Void {
		if (value < 0)
			throw 'Haxeon rejected a negative $kind';
	}

	static function requireFunctionTarget(module:HlModule, index:Int, kind:String):Void {
		if (module.functionAt(index) == null && module.nativeAt(index) == null)
			throw 'Haxeon rejected an invalid $kind target $index';
	}

	static function requireArgumentCount(operands:Array<Int>, kind:String):Void {
		requireNonNegative(operands[2], "$kind argument count");
		if (operands[2] != operands.length - 3)
			throw 'Haxeon rejected a mismatched $kind argument count';
	}

	static function requireBranch(index:Int, offset:Int, instructionCount:Int, kind:String):Void {
		var target = index + 1 + offset;
		if (target < 0 || target >= instructionCount)
			throw 'Haxeon rejected an invalid $kind target $target';
	}

	static function hasFunctionIdentity(identity:HlRuntimeManifest, stableId:Int):Bool {
		for (entry in identity.entries)
			if (entry.stableId == stableId)
				return true;
		return false;
	}

	static function identitySlot(identity:HlRuntimeManifest, stableId:Int):Int {
		for (entry in identity.entries)
			if (entry.stableId == stableId)
				return entry.functionIndex;
		return -1;
	}
}
