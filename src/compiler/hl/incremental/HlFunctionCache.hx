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
	public static inline final MAX_STABLE_ID:Int = 0x1FFFFFFF;
	public static inline final INIT_STABLE_ID:Int = MAX_STABLE_ID;

	public final userSlots:Map<String, Int> = [];
	public final stableIds:Map<String, Int> = [];
	public final slots:Array<String> = [];
	public final functions:Map<String, IrFunction> = [];
	public final signatures:Map<String, String> = [];

	var nextStableId:Int = 0x10000;

	public function new(?existingStableIds:Map<String, Int>) {
		if (existingStableIds != null)
			for (name => id in existingStableIds) {
				validateStableId(name, id);
				stableIds.set(name, id);
				if (id != INIT_STABLE_ID && id >= nextStableId)
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
		var ids:Array<HlStableFunctionState> = [for (name => id in stableIds) {name: name, id: id}];
		var signatureState:Array<HlFunctionSignatureState> = [for (name => value in signatures) {name: name, signature: value}];
		var functionState:Array<HlCachedFunctionState> = [
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
		if (state.nextStableId < 0x10000 || state.nextStableId >= INIT_STABLE_ID)
			throw "Invalid next stable function ID";
		var result = new HlFunctionCache(),
			names:Map<String, Bool> = [],
			ids:Map<Int, Bool> = [];
		for (entry in state.stableIds) {
			if (entry.name.length == 0 || names.exists(entry.name) || ids.exists(entry.id))
				throw "Invalid stable function identity state";
			validateStableId(entry.name, entry.id);
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
				if (!stableIds.exists(fn.name)) {
					if (fn.name == "__init")
						stableIds.set(fn.name, INIT_STABLE_ID);
					else {
						if (nextStableId >= INIT_STABLE_ID)
							throw "Stable function ID space exhausted";
						stableIds.set(fn.name, nextStableId++);
					}
				}
				slots.push(fn.name);
			}
			functions.set(fn.name, fn);
			signatures.set(fn.name, signature(fn));
		}
	}

	/**
	 * Renames functions, all at once: each key of `names` that the cache knows takes the value as its name, keeping its slot,
	 * stable ID, code and signature. A name nothing is renamed away from must not be taken.
	 */
	public function rename(names:Map<String, String>):Void {
		var moved:Array<{from:String, to:String}> = [];
		for (from => to in names)
			if (from != to && (userSlots.exists(from) || stableIds.exists(from)))
				moved.push({from: from, to: to});
		if (moved.length == 0)
			return;
		var sources:Map<String, Bool> = [for (entry in moved) entry.from => true];
		for (entry in moved)
			if (!sources.exists(entry.to) && (userSlots.exists(entry.to) || stableIds.exists(entry.to)))
				throw 'Cannot rename function ${entry.from} to ${entry.to}, which exists';
		var slotsOf:Map<String, Int> = [], idsOf:Map<String, Int> = [], bodies:Map<String, IrFunction> = [], signaturesOf:Map<String, String> = [];
		for (entry in moved) {
			if (userSlots.exists(entry.from))
				slotsOf.set(entry.from, userSlots.get(entry.from));
			if (stableIds.exists(entry.from))
				idsOf.set(entry.from, stableIds.get(entry.from));
			if (functions.exists(entry.from))
				bodies.set(entry.from, functions.get(entry.from));
			if (signatures.exists(entry.from))
				signaturesOf.set(entry.from, signatures.get(entry.from));
			userSlots.remove(entry.from);
			stableIds.remove(entry.from);
			functions.remove(entry.from);
			signatures.remove(entry.from);
		}
		for (entry in moved) {
			if (slotsOf.exists(entry.from)) {
				var slot = slotsOf.get(entry.from);
				userSlots.set(entry.to, slot);
				slots[slot] = entry.to;
			}
			if (idsOf.exists(entry.from))
				stableIds.set(entry.to, idsOf.get(entry.from));
			var body = bodies.get(entry.from);
			if (body != null)
				functions.set(entry.to, new IrFunction(entry.to, body.arguments, body.result, body.blocks, body.debugBindings, body.inlineHint,
					body.retention));
			if (signaturesOf.exists(entry.from))
				signatures.set(entry.to, signaturesOf.get(entry.from));
		}
	}

	/** Gives function `name`, which the cache has, the code `fn`, with the same signature (an adapter, say). */
	public function replaceBody(name:String, fn:IrFunction):Void {
		if (!functions.exists(name))
			throw 'Cannot replace the code of unknown function $name';
		if (signature(fn) != signatures.get(name))
			throw 'The new code of $name has another signature';
		functions.set(name, fn);
	}

	/**
	 * Forgets the functions `isRetired` names: their slots, code and stable IDs. Only a fresh module may drop them, since the
	 * slots of the functions after them move. Returns whether any went.
	 */
	public function dropRetired(isRetired:String->Bool):Bool {
		var kept = [for (name in slots) if (!isRetired(name)) name];
		if (kept.length == slots.length)
			return false;
		for (name in slots)
			if (isRetired(name)) {
				userSlots.remove(name);
				stableIds.remove(name);
				functions.remove(name);
				signatures.remove(name);
			}
		slots.resize(0);
		for (name in kept) {
			userSlots.set(name, slots.length);
			slots.push(name);
		}
		return true;
	}

	static function validateStableId(name:String, id:Int):Void {
		if (id < 0 || id > MAX_STABLE_ID || (id == INIT_STABLE_ID && name != "__init") || (name == "__init" && id != INIT_STABLE_ID))
			throw 'Invalid stable function ID for "$name"';
	}

	public function ordered():Array<IrFunction>
		return [for (name in slots) functions.get(name)];

	public static function signature(fn:IrFunction):String
		return "(" + [for (a in fn.arguments) Std.string(a.type)].join(",") + ")->" + Std.string(fn.result);
}
