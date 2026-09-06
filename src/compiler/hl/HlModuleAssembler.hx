package compiler.hl;

import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.hl.HlFunctionCacheStateCodec;
import compiler.hl.HlSymbolStateCodec;

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
}

class HlModuleAssembler {
	public var symbols(default, null) = new HlSymbolTable();
	public var cache(default, null):HlFunctionCache;

	var initialized:Bool = false;
	var revision:Int = 0;
	var publishedInts = 0;
	var publishedFloats = 0;
	var publishedStrings = 0;
	var publishedTypes = 0;

	public function new(?stableIds:Map<String, Int>) {
		cache = new HlFunctionCache(stableIds);
	}

	public function copy():HlModuleAssembler {
		var result = new HlModuleAssembler();
		result.symbols = symbols.copy();
		result.cache = cache.copy();
		result.initialized = initialized;
		result.revision = revision;
		result.publishedInts = publishedInts;
		result.publishedFloats = publishedFloats;
		result.publishedStrings = publishedStrings;
		result.publishedTypes = publishedTypes;
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
		cache.update(program.functions);
		var ordered = new IrProgram(program.entryPoint);
		ordered.natives = program.natives;
		ordered.objects = program.objects;
		ordered.interfaces = program.interfaces;
		ordered.enums = program.enums;
		ordered.staticFields = program.staticFields;
		ordered.functions = cache.ordered();
		var layout:Map<String, Int> = [], next = 0;
		for (native in ordered.natives)
			layout.set(native.name, next++);
		for (name in cache.slots)
			layout.set(name, next++);
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
		var reload = switch decision {
			case Patch: false;
			case ReloadDomain(_): true;
			case Reject(diagnostics): throw diagnostics.join("; ");
		};
		var module = HlLower.lowerStable(ordered, symbols, layout);
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
			baseTypes: baseTypes
		};
	}
}
