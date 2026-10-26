package compiler.hl.incremental;

import compiler.ir.hl.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.persistence.HlFunctionCacheStateCodec;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.hl.patch.HlPatchWriter;
import compiler.ir.Ir.IrNative;
import compiler.ir.hl.HlDebugMetadataCache;
import compiler.compilation.AllocationMeter.PhaseAllocation;

/** Persisted append-only symbol and function baseline for incremental assembly. */
typedef HlAssemblerState = {
	final initialized:Bool;
	final revision:Int;
	final publishedInts:Int;
	final publishedFloats:Int;
	final publishedStrings:Int;
	final publishedTypes:Int;

	/** Globals the published module holds. Absent in older baselines, which published no literal globals. */
	@:optional final publishedGlobals:Int;

	final symbols:haxe.io.Bytes;
	final cache:haxe.io.Bytes;
	@:optional final runtimeNatives:Array<IrNative>;

	/** Names of the C dispatch natives, which follow the runtime natives in the layout. Absent in older baselines. */
	@:optional final dispatchNatives:Array<String>;
}

/** Module plus identity and delta metadata produced by one assembly transaction. */
typedef HlAssemblyResult = {
	final module:HlCode;
	final changedFunctions:Array<Int>;
	final changedSlots:Array<Int>;

	/** Slots this build gives functions the published module does not have, in slot order, with their names. */
	final addedFunctions:Array<{slot:Int, name:String}>;

	final functionIndices:Map<String, Int>;
	final requiresReload:Bool;
	final revision:Int;
	final baseInts:Int;
	final baseFloats:Int;
	final baseStrings:Int;
	final baseTypes:Int;

	/** Globals the running module has, which a patch's new literal globals follow. */
	final baseGlobals:Int;

	final cachePreparationMs:Float;
	final loweringMs:Float;
	final publicationMs:Float;
	final verificationMs:Float;
	final metadataMs:Float;
	final functionLoweringMs:Float;
	final debugAssemblyMs:Float;
	final lowerFinalizationMs:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/**
 * Stateful IR-to-HashLink assembler with append-only published indices.
 * Callers publish or discard a copied instance as one compiler transaction.
 */
class HlModuleAssembler {
	public var symbols(default, null) = new HlSymbolTable();
	public var cache(default, null):HlFunctionCache;

	var initialized:Bool = false;
	var revision:Int = 0;
	var publishedInts = 0;
	var publishedFloats = 0;
	var publishedStrings = 0;
	var publishedTypes = 0;
	var publishedGlobals = 0;
	var loweredFunctions:Map<String, HlFunction> = [];
	var runtimeNatives:Array<IrNative> = [];

	/** Null when a restored baseline does not record them, so the next build cannot trust their slots. */
	var dispatchNatives:Null<Array<String>> = [];

	final debugMetadata:HlDebugMetadataCache;

	public function new(?stableIds:Map<String, Int>, ?sharedDebugMetadata:HlDebugMetadataCache) {
		cache = new HlFunctionCache(stableIds);
		debugMetadata = sharedDebugMetadata == null ? new HlDebugMetadataCache() : sharedDebugMetadata;
	}

	public function copy():HlModuleAssembler {
		var result = new HlModuleAssembler(null, debugMetadata);
		result.symbols = symbols.fork();
		result.cache = cache.copy();
		result.initialized = initialized;
		result.revision = revision;
		result.publishedInts = publishedInts;
		result.publishedFloats = publishedFloats;
		result.publishedStrings = publishedStrings;
		result.publishedTypes = publishedTypes;
		result.publishedGlobals = publishedGlobals;
		result.loweredFunctions = [for (name => fn in loweredFunctions) name => fn];
		result.runtimeNatives = runtimeNatives.copy();
		result.dispatchNatives = dispatchNatives == null ? null : dispatchNatives.copy();
		return result;
	}

	public function exportState():HlAssemblerState
		return {
			initialized: initialized,
			revision: revision,
			publishedInts: publishedInts,
			publishedFloats: publishedFloats,
			publishedStrings: publishedStrings,
			publishedTypes: publishedTypes,
			publishedGlobals: publishedGlobals,
			symbols: HlSymbolStateCodec.encode(symbols.exportState()),
			cache: HlFunctionCacheStateCodec.encode(cache.exportState()),
			runtimeNatives: runtimeNatives.copy(),
			dispatchNatives: dispatchNatives == null ? null : dispatchNatives.copy()
		};

	public static function fromState(state:HlAssemblerState):HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = HlSymbolStateCodec.restore(state.symbols);
		result.cache = HlFunctionCacheStateCodec.restore(state.cache);
		if (state.runtimeNatives != null)
			result.runtimeNatives = state.runtimeNatives.copy();
		else if (state.initialized)
			// Import indices are part of the published layout; guessing can patch the wrong slots.
			throw "Legacy assembler state lacks native-import ordering; rebuild the baseline";
		result.dispatchNatives = state.dispatchNatives == null ? null : state.dispatchNatives.copy();
		if (state.revision < 0
			|| state.publishedInts < 0
			|| state.publishedFloats < 0
			|| state.publishedStrings < 0
			|| state.publishedTypes < 0
			|| state.publishedGlobals != null
			&& state.publishedGlobals < 0
			|| state.publishedInts > result.symbols.ints.length
			|| state.publishedFloats > result.symbols.floats.length
			|| state.publishedStrings > result.symbols.strings.length
			|| state.publishedTypes > result.symbols.types.length
			|| state.publishedGlobals != null
			&& state.publishedGlobals > result.symbols.globals.length
			|| (!state.initialized && state.revision != 0)
			|| (state.initialized && state.revision == 0))
			throw "Invalid HashLink assembler baseline";
		result.initialized = state.initialized;
		result.revision = state.revision;
		result.publishedInts = state.publishedInts;
		result.publishedFloats = state.publishedFloats;
		result.publishedStrings = state.publishedStrings;
		result.publishedTypes = state.publishedTypes;
		// A baseline from before literals became globals published every global it had.
		result.publishedGlobals = state.publishedGlobals == null ? result.symbols.globals.length : state.publishedGlobals;
		return result;
	}

	/**
	 * Forgets every published symbol index. Interned object types record the slot of each method, so once
	 * the slot layout has moved they would point every method table at a neighbouring function; a module
	 * that cannot be patched must intern its types afresh against the new layout.
	 */
	function discardPublishedSymbols():Void {
		symbols = new HlSymbolTable();
		loweredFunctions = [];
		publishedInts = 0;
		publishedFloats = 0;
		publishedStrings = 0;
		publishedTypes = 0;
		publishedGlobals = 0;
	}

	function addsOnlyConstantGlobals(total:Int):Bool {
		var constants = symbols.stringConstantGlobals(), added = 0, index = constants.length - 1;
		while (index >= 0 && constants[index].global >= publishedGlobals) {
			added++;
			index--;
		}
		return added == total - publishedGlobals;
	}

	static function sameNames(previous:Null<Array<String>>, next:Array<String>):Bool {
		if (previous == null || previous.length != next.length)
			return false;
		for (index in 0...next.length)
			if (previous[index] != next[index])
				return false;
		return true;
	}

	public function assemble(program:IrProgram, regenerated:Array<String>, decision:PatchDecision, ?relocated:Array<String>):HlAssemblyResult {
		var startedAt = Sys.time() * 1000.0,
			publishedSlots = cache.slots.length;
		cache.update(program.functions);
		var ordered = new IrProgram(program.entryPoint);
		ordered.natives = program.natives;
		ordered.cNatives = program.cNatives;
		ordered.objects = program.objects;
		ordered.interfaces = program.interfaces;
		ordered.enums = program.enums;
		ordered.staticFields = program.staticFields;
		ordered.functions = cache.ordered();
		var reload = switch decision {
			case Patch: false;
			case ReloadDomain(_): true;
			case Reject(diagnostics): throw diagnostics.join("; ");
		};
		var reuseLowered = initialized && !reload;
		// A domain reload rediscovers native imports without preserving their old slots.
		// Cached object prototypes contain absolute function indices, just like opcodes.
		if (initialized && reload)
			discardPublishedSymbols();
		var cachePreparedAt = Sys.time() * 1000.0;
		var previousNatives = runtimeNatives;
		runtimeNatives = HlLower.discoverRuntimeNatives(ordered, reuseLowered && previousNatives.length > 0 ? previousNatives : null, reuseLowered && previousNatives.length > 0 ? regenerated : null);
		// New runtime imports shift every function slot. Publish a fresh module,
		// never reuse opcodes or patch a live module with the old slot layout.
		if (reuseLowered && runtimeNatives.length != previousNatives.length) {
			reload = true;
			reuseLowered = false;
			discardPublishedSymbols();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered);
		}
		// C dispatch natives sit with the runtime natives, before every function slot. When they change, every function slot
		// moves, so publish a fresh module.
		var nextDispatch = [for (native in HlLower.discoverCDispatchNatives(ordered)) native.name];
		if (reuseLowered && !sameNames(dispatchNatives, nextDispatch)) {
			reload = true;
			reuseLowered = false;
			discardPublishedSymbols();
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered);
		}
		dispatchNatives = nextDispatch;
		var layout:Map<String, Int> = [], next = 0;
		for (native in runtimeNatives)
			layout.set(native.name, next++);
		for (name in nextDispatch)
			layout.set(name, next++);
		for (name in cache.slots)
			layout.set(name, next++);
		if (reuseLowered)
			for (fn in ordered.functions) {
				var previous = loweredFunctions.get(fn.name);
				if (previous != null && previous.functionIndex != layout.get(fn.name)) {
					reload = true;
					reuseLowered = false;
					discardPublishedSymbols();
					break;
				}
			}
		var changed:Array<Int> = [], changedSlots:Array<Int> = [];
		if (initialized)
			for (name in regenerated) {
				if (layout.exists(name) && cache.stableIds.exists(name)) {
					var index = layout.get(name),
						stableId = cache.stableIds.get(name);
					changedSlots.push(index);
					changed.push(stableId);
				}
			}
		changed.sort(function(a, b) return a - b);
		changedSlots.sort(function(a, b) return a - b);
		var addedFunctions:Array<{slot:Int, name:String}> = [];
		if (initialized && !reload)
			for (index in publishedSlots...cache.slots.length) {
				var name = cache.slots[index], slot = layout.get(name);
				if (slot == null)
					throw 'Added function $name has no slot';
				addedFunctions.push({slot: slot, name: name});
			}
		var lowered = HlLower.lowerStableMeasured(ordered, symbols, layout, cache.stableIds, reuseLowered ? loweredFunctions : null,
			relocated == null ? regenerated : regenerated.concat(relocated),
			runtimeNatives, debugMetadata),
			module = lowered.code;
		var loweredAt = Sys.time() * 1000.0;
		// A running module can take new String constants but no other global, so a build that adds any other publishes a
		// fresh module. The ABI plan already asks for that when a static field is added; this guards the rest.
		if (initialized && !reload && !addsOnlyConstantGlobals(module.globals.length))
			reload = true;
		loweredFunctions = [];
		for (index in 0...ordered.functions.length)
			loweredFunctions.set(ordered.functions[index].name, module.functions[index]);
		var baseInts = publishedInts,
			baseFloats = publishedFloats,
			baseStrings = publishedStrings,
			baseTypes = publishedTypes,
			baseGlobals = publishedGlobals;
		publishedInts = module.ints.length;
		publishedFloats = module.floats.length;
		publishedStrings = module.strings.length;
		publishedTypes = module.types.length;
		publishedGlobals = module.globals.length;
		// A build that changes nothing the running module holds (a resumed session warming up, a save that only touched
		// what lowering ignores) is the published revision again: a new revision would carry no patch, and the runtime
		// can only reach a revision without a patch by reloading.
		var unchanged = initialized && !reload && changed.length == 0 && addedFunctions.length == 0 && baseInts == publishedInts
			&& baseFloats == publishedFloats && baseStrings == publishedStrings && baseTypes == publishedTypes && baseGlobals == publishedGlobals;
		if (!unchanged)
			revision++;
		initialized = true;
		return {
			module: module,
			changedFunctions: changed,
			changedSlots: changedSlots,
			addedFunctions: addedFunctions,
			functionIndices: layout,
			requiresReload: reload,
			revision: revision,
			baseInts: baseInts,
			baseFloats: baseFloats,
			baseStrings: baseStrings,
			baseTypes: baseTypes,
			baseGlobals: baseGlobals,
			cachePreparationMs: cachePreparedAt - startedAt,
			loweringMs: loweredAt - cachePreparedAt,
			publicationMs: Sys.time() * 1000.0 - loweredAt,
			verificationMs: lowered.metrics.verificationMs,
			metadataMs: lowered.metrics.metadataMs,
			functionLoweringMs: lowered.metrics.functionsMs,
			debugAssemblyMs: lowered.metrics.debugMs,
			lowerFinalizationMs: lowered.metrics.finalizationMs,
			allocationPhases: lowered.metrics.allocationPhases
		};
	}
}
