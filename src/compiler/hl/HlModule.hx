package compiler.hl;

import haxe.io.Bytes;
import compiler.hl.HlCode.HlConstant;
import compiler.hl.HlCode.HlDebugSection;
import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.hl.HlCode.HlNative;
import compiler.hl.HlCode.HlSourceSnapshot;
import compiler.hl.HlCode.HlTypeDef;

/** Validated HLB module model owned by Haxeon between decode and publication. */
class HlModule {
	/** The canonical HLB data retained for writers and metadata builders. */
	public final code:HlCode;

	public final entryPoint:Int;
	public final dispatchSlotCount:Int;

	final functionsBySlot:Map<Int, HlFunction> = [];
	final nativesBySlot:Map<Int, HlNative> = [];
	final identitiesBySlot:Map<Int, HlFunctionIdentity> = [];
	final identitiesByStableId:Map<Int, Bool> = [];

	public function new(code:HlCode) {
		if (code == null)
			throw "HashLink module model requires HLB data";
		HlValidator.validate(code);
		this.code = code;
		entryPoint = code.entryPoint;
		var maximumSlot = -1;
		for (native in code.natives) {
			if (nativesBySlot.exists(native.functionIndex))
				throw 'HashLink module has duplicate native dispatch slot ${native.functionIndex}';
			nativesBySlot.set(native.functionIndex, native);
			if (native.functionIndex > maximumSlot)
				maximumSlot = native.functionIndex;
		}
		for (fn in code.functions) {
			if (functionsBySlot.exists(fn.functionIndex))
				throw 'HashLink module has duplicate bytecode dispatch slot ${fn.functionIndex}';
			functionsBySlot.set(fn.functionIndex, fn);
			if (fn.functionIndex > maximumSlot)
				maximumSlot = fn.functionIndex;
		}
		for (identity in code.functionIdentities) {
			if (identity.stableId < 0)
				throw 'HashLink function identity ${identity.functionIndex} has a negative stable ID';
			if (!functionsBySlot.exists(identity.functionIndex))
				throw 'HashLink function identity references missing bytecode function ${identity.functionIndex}';
			if (identitiesBySlot.exists(identity.functionIndex))
				throw 'HashLink module has duplicate function identity slot ${identity.functionIndex}';
			if (identitiesByStableId.exists(identity.stableId))
				throw 'HashLink module has duplicate stable function ID ${identity.stableId}';
			identitiesBySlot.set(identity.functionIndex, identity);
			identitiesByStableId.set(identity.stableId, true);
		}
		dispatchSlotCount = maximumSlot + 1;
	}

	/** Decode and validate one complete standard HLB module. */
	public static function decode(bytes:Bytes):HlModule
		return new HlModule(HlReader.decode(bytes));

	/** Encode this validated model using the canonical HLB representation. */
	public function encode():Bytes
		return HlWriter.encode(code);

	/** Return the type-table definition at a module-local index. */
	public function typeAt(index:Int):HlTypeDef {
		if (index < 0 || index >= code.types.length)
			throw 'HashLink module type index $index is outside 0...${code.types.length}';
		return code.types[index];
	}

	/** Return the bytecode function occupying a dispatch slot, if any. */
	public function functionAt(slot:Int):Null<HlFunction>
		return functionsBySlot.get(slot);

	/** Return the native binding occupying a dispatch slot, if any. */
	public function nativeAt(slot:Int):Null<HlNative>
		return nativesBySlot.get(slot);

	/** Return stable function identity metadata for a dispatch slot, if present. */
	public function identityAt(slot:Int):Null<HlFunctionIdentity>
		return identitiesBySlot.get(slot);

	/** Return the stable identity for a bytecode slot, defaulting to its slot. */
	public function stableIdAt(slot:Int):Int {
		var identity = identityAt(slot);
		return identity == null ? slot : identity.stableId;
	}

	/** Return all occupied dispatch slots in deterministic order. */
	public function dispatchSlots():Array<Int> {
		var result:Map<Int, Bool> = [];
		for (slot in functionsBySlot.keys())
			result.set(slot, true);
		for (slot in nativesBySlot.keys())
			result.set(slot, true);
		var slots = [for (slot in result.keys()) slot];
		slots.sort(Reflect.compare);
		return slots;
	}

	/** Return the number of decoded scalar pools and metadata tables. */
	public inline function typeCount():Int
		return code.types.length;

	public inline function globalCount():Int
		return code.globals.length;

	public inline function functionCount():Int
		return code.functions.length;

	public inline function nativeCount():Int
		return code.natives.length;

	public inline function constantCount():Int
		return code.constants.length;

	public inline function debugSectionCount():Int
		return code.debugSections.length;

	/** Keep the source/debug tables visible without exposing another representation. */
	public inline function sourceSnapshots():Array<HlSourceSnapshot>
		return code.sourceSnapshots;

	public inline function constants():Array<HlConstant>
		return code.constants;

	public inline function debugSections():Array<HlDebugSection>
		return code.debugSections;
}
