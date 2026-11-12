package compiler.backend.wasm.gc;

import compiler.backend.wasm.gc.WasmGcTypePlan;
import compiler.ir.Ir.IrEnum;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmHeapType;

/** Module-lifetime configuration and indices for native Wasm GC lowering. */
class WasmGcContext {
	public final module:WasmModule;
	public final plan:WasmGcTypePlan;

	public final functions:Map<String, Int>;
	public final globals:Map<String, Int>;
	public final methods:Map<String, String>;
	public var tableSlots:Map<String, Int> = [];
	public var stringifiableEnums:Map<String, Bool> = [];
	public var enumStringTable:Null<{
		segment:Int,
		words:Int,
		names:Int,
		dataGlobal:Int,
		cacheGlobal:Int,
		dataTypeIndex:Int,
		cacheTypeIndex:Int,
		narrow:Bool
	}>;

	/** Logical declarations remain available when release mode drops a tag's boxed descriptor. */
	public var enumDeclarations:Array<IrEnum> = [];

	/** Generated adapter targets whose static closures are only receiver-query markers. */
	public final closureProbeTargets:Map<String, Bool> = [];

	public final closureProbeQueryTargets:Map<String, String> = [];

	final stringSegments:Map<String, Int> = [];
	final stringGlobals:Map<String, Int> = [];
	final valueArrayBridgeGlobals:Map<String, Int> = [];
	final enumCaseGlobals:Map<String, Int> = [];
	var enumTagAdapters:Null<Map<String, {box:Null<String>, unbox:Null<String>}>>;

	public function new(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, globals:Map<String, Int>, methods:Map<String, String>) {
		this.module = module;
		this.plan = plan;
		this.functions = functions;
		this.globals = globals;
		this.methods = methods;
	}

	public function enumTagAdapter(name:String, box:Bool):String {
		if (enumTagAdapters == null) {
			enumTagAdapters = [];
			for (fn in plan.program.functions)
				switch fn.kind {
					case EnumTagAdapter(EnumTag(type), isBox):
						var entry = enumTagAdapters.get(type);
						if (entry == null) {
							entry = {box: null, unbox: null};
							enumTagAdapters.set(type, entry);
						}
						if (isBox)
							entry.box = fn.name;
						else
							entry.unbox = fn.name;
					default:
				}
		}
		var entry = enumTagAdapters.get(name),
			result = entry == null ? null : (box ? entry.box : entry.unbox);
		if (result == null)
			throw 'Missing enum tag adapter for $name';
		return result;
	}

	/** The passive data segment holding a string literal's UTF-8 bytes, shared by every use of that literal. */
	public function stringSegment(value:String):Int {
		var segment = stringSegments.get(value);
		if (segment == null) {
			segment = module.data.length;
			module.data.push({
				offset: 0,
				bytes: haxe.io.Bytes.ofString(value),
				passive: true,
				censusCategory: "strings"
			});
			stringSegments.set(value, segment);
		}
		return segment;
	}

	/** Literals are immutable, so every evaluation can share one rooted value per module. */
	public function stringGlobal(value:String):Int {
		var existing = stringGlobals.get(value);
		if (existing != null)
			return existing;
		var index = module.globals.length,
			heap:WasmHeapType = Type(plan.bytesTypeIndex);
		module.globals.push({type: Ref({nullable: true, heap: heap}), mutable: true, init: [RefNull(heap)]});
		stringGlobals.set(value, index);
		return index;
	}

	/** One lazily initialized closure per generated bridge, shared by every array of that shape. */
	public function valueArrayBridgeGlobal(name:String):Int {
		var existing = valueArrayBridgeGlobals.get(name);
		if (existing != null)
			return existing;
		var index = module.globals.length,
			heap:WasmHeapType = Type(plan.closureTypeIndex);
		module.globals.push({type: Ref({nullable: true, heap: heap}), mutable: true, init: [RefNull(heap)]});
		valueArrayBridgeGlobals.set(name, index);
		return index;
	}

	/** Immutable nullary cases share one managed root per constructor in this module. */
	public function enumCaseGlobal(name:String, constructor:Int):Int {
		var key = compiler.backend.wasm.WasmModuleSupport.enumCaseKey(name, constructor),
			existing = enumCaseGlobals.get(key);
		if (existing != null)
			return existing;
		var index = module.globals.length,
			heap:WasmHeapType = Type(plan.enumType(name));
		module.globals.push({type: Ref({nullable: true, heap: heap}), mutable: true, init: [RefNull(heap)]});
		enumCaseGlobals.set(key, index);
		return index;
	}
}
