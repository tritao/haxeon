package compiler.hl.incremental;

import compiler.hl.HlWriter;
import compiler.hl.HlFunction;
import compiler.ir.IrFunction;
import compiler.ir.codec.IrFunctionStateCodec;

/** Serialized SSA body associated with a cached function name. */
typedef HlCachedFunctionState = {final name:String; final bytes:haxe.io.Bytes;}

/** Persistent stable runtime identity associated with a function name. */
typedef HlStableFunctionState = {final name:String; final id:Int;}

/** Cached semantic signature used to classify function changes. */
typedef HlFunctionSignatureState = {final name:String; final signature:String;}

/** Complete persistable state of append-only function slots and bodies. */
typedef HlFunctionCacheState = {
	final slots:Array<String>;
	final stableIds:Array<HlStableFunctionState>;
	final signatures:Array<HlFunctionSignatureState>;
	final functions:Array<HlCachedFunctionState>;
	final nextStableId:Int;
}

/**
 * Owns append-only user-function slots and stable runtime IDs.
 * Removed names retain their slots until an explicit assembler compaction.
 */
class HlFunctionCache {
	public static inline final INIT_STABLE_ID:Int = 0x7FFF0000;

	public final userSlots:Map<String, Int> = [];
	public final stableIds:Map<String, Int> = [];
	public final slots:Array<String> = [];
	public final functions:Map<String, IrFunction> = [];
	public final signatures:Map<String, String> = [];

	var nextStableId:Int = 0x10000;

	public function new(?existingStableIds:Map<String, Int>) {
		if (existingStableIds != null)
			for (name => id in existingStableIds) {
				stableIds.set(name, id);
				if (id >= nextStableId)
					nextStableId = id + 1;
			}
	}

	public function copy():HlFunctionCache {
		var result = new HlFunctionCache();
		for (name => slot in userSlots)
			result.userSlots.set(name, slot);
		for (name => id in stableIds)
			result.stableIds.set(name, id);
		for (name in slots)
			result.slots.push(name);
		for (name => fn in functions)
			result.functions.set(name, fn);
		for (name => signature in signatures)
			result.signatures.set(name, signature);
		result.nextStableId = nextStableId;
		return result;
	}

	public function exportState():HlFunctionCacheState {
		var ids = [for (name => id in stableIds) {name: name, id: id}],
			signatureState = [for (name => value in signatures) {name: name, signature: value}],
			functionState = [
				for (name => fn in functions)
					{name: name, bytes: IrFunctionStateCodec.encode(fn)}
			];
		ids.sort(function(a, b) return Reflect.compare(a.name, b.name));
		signatureState.sort(function(a, b) return Reflect.compare(a.name, b.name));
		functionState.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return {
			slots: slots.copy(),
			stableIds: ids,
			signatures: signatureState,
			functions: functionState,
			nextStableId: nextStableId
		};
	}

	public static function fromState(state:HlFunctionCacheState):HlFunctionCache {
		if (state.nextStableId < 0x10000)
			throw "Invalid next stable function ID";
		var result = new HlFunctionCache(),
			names:Map<String, Bool> = [],
			ids:Map<Int, Bool> = [];
		for (entry in state.stableIds) {
			if (entry.name.length == 0 || entry.id < 0 || names.exists(entry.name) || ids.exists(entry.id))
				throw "Invalid stable function identity state";
			names.set(entry.name, true);
			ids.set(entry.id, true);
			result.stableIds.set(entry.name, entry.id);
		}
		for (slot in 0...state.slots.length) {
			var name = state.slots[slot];
			if (!names.exists(name) || result.userSlots.exists(name))
				throw "Invalid function slot state";
			result.slots.push(name);
			result.userSlots.set(name, slot);
		}
		for (entry in state.functions) {
			if (!result.userSlots.exists(entry.name) || result.functions.exists(entry.name))
				throw "Invalid cached function state";
			var fn = compiler.ir.codec.IrFunctionStateCodec.decode(entry.bytes);
			if (fn.name != entry.name)
				throw "Cached function name mismatch";
			result.functions.set(entry.name, fn);
		}
		for (entry in state.signatures) {
			if (!result.functions.exists(entry.name) || result.signatures.exists(entry.name))
				throw "Invalid function signature state";
			var fn = result.functions.get(entry.name);
			if (entry.signature != signature(fn))
				throw "Cached function signature mismatch";
			result.signatures.set(entry.name, entry.signature);
		}
		for (name in result.slots)
			if (!result.functions.exists(name) || !result.signatures.exists(name))
				throw "Incomplete function cache state";
		result.nextStableId = state.nextStableId;
		return result;
	}

	public function update(incoming:Array<IrFunction>):Void {
		for (fn in incoming) {
			if (!userSlots.exists(fn.name)) {
				userSlots.set(fn.name, slots.length);
				if (!stableIds.exists(fn.name))
					stableIds.set(fn.name, fn.name == "__init" ? INIT_STABLE_ID : nextStableId++);
				slots.push(fn.name);
			}
			functions.set(fn.name, fn);
			signatures.set(fn.name, signature(fn));
		}
	}

	public function ordered():Array<IrFunction>
		return [for (name in slots) functions.get(name)];

	public static function signature(fn:IrFunction):String
		return "(" + [for (a in fn.arguments) Std.string(a.type)].join(",") + ")->" + Std.string(fn.result);
}
