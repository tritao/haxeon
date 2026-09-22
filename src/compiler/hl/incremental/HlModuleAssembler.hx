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
	final symbols:haxe.io.Bytes;
	final cache:haxe.io.Bytes;
}

/** Module plus identity and delta metadata produced by one assembly transaction. */
typedef HlAssemblyResult = {
	final module:HlCode;
	final changedFunctions:Array<Int>;
	final changedSlots:Array<Int>;
	final functionIndices:Map<String, Int>;
	final requiresReload:Bool;
	final revision:Int;
	final baseInts:Int;
	final baseFloats:Int;
	final baseStrings:Int;
	final baseTypes:Int;
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
	var loweredFunctions:Map<String, HlFunction> = [];
	var runtimeNatives:Array<IrNative> = [];
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
		result.loweredFunctions = [for (name => fn in loweredFunctions) name => fn];
		result.runtimeNatives = runtimeNatives.copy();
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
			symbols: HlSymbolStateCodec.encode(symbols.exportState()),
			cache: HlFunctionCacheStateCodec.encode(cache.exportState())
		};

	public static function fromState(state:HlAssemblerState):HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = HlSymbolStateCodec.restore(state.symbols);
		result.cache = HlFunctionCacheStateCodec.restore(state.cache);
		if (state.revision < 0
			|| state.publishedInts < 0
			|| state.publishedFloats < 0
			|| state.publishedStrings < 0
			|| state.publishedTypes < 0
			|| state.publishedInts > result.symbols.ints.length
			|| state.publishedFloats > result.symbols.floats.length
			|| state.publishedStrings > result.symbols.strings.length
			|| state.publishedTypes > result.symbols.types.length
			|| (!state.initialized && state.revision != 0)
			|| (state.initialized && state.revision == 0))
			throw "Invalid HashLink assembler baseline";
		result.initialized = state.initialized;
		result.revision = state.revision;
		result.publishedInts = state.publishedInts;
		result.publishedFloats = state.publishedFloats;
		result.publishedStrings = state.publishedStrings;
		result.publishedTypes = state.publishedTypes;
		return result;
	}

	public function assemble(program:IrProgram, regenerated:Array<String>, decision:PatchDecision):HlAssemblyResult {
		var startedAt = Sys.time() * 1000.0;
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
		var cachePreparedAt = Sys.time() * 1000.0;
		var previousNatives = runtimeNatives;
		runtimeNatives = HlLower.discoverRuntimeNatives(ordered, reuseLowered && previousNatives.length > 0 ? previousNatives : null,
			reuseLowered && previousNatives.length > 0 ? regenerated : null);
		// New runtime imports shift every function slot. Publish a fresh module,
		// never reuse opcodes or patch a live module with the old slot layout.
		if (reuseLowered && runtimeNatives.length != previousNatives.length) {
			reload = true;
			reuseLowered = false;
			runtimeNatives = HlLower.discoverRuntimeNatives(ordered);
		}
		var layout:Map<String, Int> = [], next = 0;
		for (native in runtimeNatives)
			layout.set(native.name, next++);
		for (name in cache.slots)
			layout.set(name, next++);
		if (reuseLowered)
			for (fn in ordered.functions) {
				var previous = loweredFunctions.get(fn.name);
				if (previous != null && previous.functionIndex != layout.get(fn.name)) {
					reload = true;
					reuseLowered = false;
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
		var lowered = HlLower.lowerStableMeasured(ordered, symbols, layout, cache.stableIds, reuseLowered ? loweredFunctions : null, regenerated,
			runtimeNatives, debugMetadata),
			module = lowered.code;
		var loweredAt = Sys.time() * 1000.0;
		loweredFunctions = [];
		for (index in 0...ordered.functions.length)
			loweredFunctions.set(ordered.functions[index].name, module.functions[index]);
		var baseInts = publishedInts,
			baseFloats = publishedFloats,
			baseStrings = publishedStrings,
			baseTypes = publishedTypes;
		publishedInts = module.ints.length;
		publishedFloats = module.floats.length;
		publishedStrings = module.strings.length;
		publishedTypes = module.types.length;
		revision++;
		initialized = true;
		return {
			module: module,
			changedFunctions: changed,
			changedSlots: changedSlots,
			functionIndices: layout,
			requiresReload: reload,
			revision: revision,
			baseInts: baseInts,
			baseFloats: baseFloats,
			baseStrings: baseStrings,
			baseTypes: baseTypes,
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
