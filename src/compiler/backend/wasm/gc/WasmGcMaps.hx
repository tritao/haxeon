package compiler.backend.wasm.gc;

import compiler.backend.wasm.gc.WasmGcTypePlan.WasmGcMapTypePlan;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;

/** The functions every operation on one map type shares: all take the map first and work through its hash index. */
typedef WasmGcMapHelpers = {
	final hash:Int;
	final findSlot:Int;
	final find:Int;
	final insertSlot:Int;
	final rebuild:Int;
	final removeSlot:Int;
}

/** Lowers specialized Haxe maps to GC structs: dense typed key and value arrays in insertion order, plus a hash index of entry positions. */
class WasmGcMaps {
	public static function add(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, native:IrNative, mapName:String, operation:String):Int {
		var map = plan.mapPlan(mapName),
			mapType = plan.mapType(mapName),
			mapReference = Ref({nullable: true, heap: Type(mapType)}),
			name = '__${mapName}_$operation';
		return switch operation {
			case "alloc": addAlloc(module, name, plan, map, mapType, mapReference);
			case "set": addSet(module, name, plan, map, mapType, mapReference, ensureHelpers(module, functions, plan, mapName));
			case "exists": addExists(module, name, plan, map, mapType, mapReference, ensureHelpers(module, functions, plan, mapName).find);
			case "get": addGet(module, name, plan, map, mapType, mapReference, ensureHelpers(module, functions, plan, mapName).find);
			case "keys": addProjectionForNative(module, name, plan, native, map, mapType, mapReference, true);
			case "values": addProjectionForNative(module, name, plan, native, map, mapType, mapReference, false);
			case "remove": addRemove(module, name, plan, map, mapType, mapReference, ensureHelpers(module, functions, plan, mapName));
			case "clear": addClear(module, name, plan, map, mapType, mapReference);
			case "copy": addCopy(module, name, plan, map, mapType, mapReference);
			case "size": module.addFunction(new WasmFunction(name, {parameters: [mapReference], results: [I32]}, [],
					[LocalGet(0), StructGet(mapType, 0), Return]));
			default: throw 'Unknown Wasm GC map operation "$operation"';
		};
	}

	public static function projectionName(nativeName:String, outputType:IrType):String
		return '__haxeon_gc_map_projection_${nativeName}_${WasmGcTypePlan.typeKey(outputType)}';

	public static function addProjectionForCall(module:WasmModule, plan:WasmGcTypePlan, native:IrNative, mapName:String, operation:String,
			outputType:IrType):Int {
		var map = plan.mapPlan(mapName),
			mapType = plan.mapType(mapName),
			mapReference = Ref({nullable: true, heap: Type(mapType)}),
			keys = operation == "keys";
		if (operation != "keys" && operation != "values")
			throw 'Wasm GC native ${native.name} is not a map projection';
		return addProjection(module, projectionName(native.name, outputType), plan, map, mapType, mapReference, outputType, keys);
	}

	/**
	 * The hash index of a map: an `i32` array whose slots hold an entry position plus one (zero is empty), probed
	 * linearly from the key's hash and sized to at least twice the entry capacity, so it is never more than half full.
	 * Deleting a slot shifts later members of its probe run back, so there are no tombstones and a lookup stops at
	 * the first empty slot.
	 */
	static function ensureHelpers(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, mapName:String):WasmGcMapHelpers {
		var prefix = '__haxeon_gc_map_';
		var map = plan.mapPlan(mapName),
			mapType = plan.mapType(mapName),
			mapReference:WasmValueType = Ref({nullable: true, heap: Type(mapType)}),
			keyArray = plan.arrayType(map.keyType),
			keyStorage = plan.arrayStorageType(map.keyType),
			keyValue = plan.valueType(map.keyType),
			indexType = plan.mapIndexTypeIndex,
			indexReference:WasmValueType = Ref({
				nullable: false,
				heap: Type(indexType)
			}),
			stringEqual = map.keyType == Bytes ? ensureStringEqual(module, functions, plan) : -1;
		/** The key stored at the entry whose position the instructions leave on the stack. */
		function keyAt(mapLocal:Int, entry:Array<WasmInstruction>):Array<WasmInstruction>
			return [
				LocalGet(mapLocal),
				StructGet(mapType, 2),
				StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(keyStorage)})
			].concat(entry).concat([ArrayGet(keyStorage)]);
		function define(name:String, type:WasmFunctionType, locals:Array<WasmLocal>, body:Array<WasmInstruction>):Int {
			var existing = functions.get(name);
			if (existing != null)
				return existing;
			var index = module.addFunction(new WasmFunction(name, type, locals, body));
			functions.set(name, index);
			return index;
		}
		// hash(key): a multiplicative mix for Int keys, FNV-1a over the bytes for String keys, then folded
		var hash = if (map.keyType == Bytes) define(prefix + 'hash_' + mapName, {parameters: [keyValue], results: [I32]}, [
			{type: I32},
			{type: I32},
			{type: I32},
			{type: Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})},
			{type: I32}
		], [
			LocalGet(0),
			RefIsNull,
			If(null),
			I32Const(0),
			Return,
			End,
			I32Const(-2128831035),
			LocalSet(1),
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 0),
			LocalSet(4),
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 1),
			LocalSet(5),
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 2),
			LocalSet(3),
			I32Const(0),
			LocalSet(2),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(3),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(1),
			LocalGet(4),
			LocalGet(5),
			LocalGet(2),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			I32Xor,
			I32Const(16777619),
			I32Mul,
			LocalSet(1),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(0),
			End,
			End,
			LocalGet(1),
			LocalGet(1),
			I32Const(15),
			I32ShrU,
			I32Xor,
			Return
		]) else define(prefix + 'hash_' + mapName, {
			parameters: [keyValue],
			results: [I32]
		}, [{type: I32}], [
			LocalGet(0),
			I32Const(-1640531535),
			I32Mul,
			LocalSet(1),
			LocalGet(1),
			LocalGet(1),
			I32Const(15),
			I32ShrU,
			I32Xor,
			Return
		]);
		// findSlot(map, key): the index slot holding the key, or -1
		var findSlot = define(prefix + 'find_slot_' + mapName, {parameters: [mapReference, keyValue], results: [I32]},
			[{type: indexReference}, {type: I32}, {type: I32}, {type: I32}], [
				LocalGet(0),
				StructGet(mapType, 4),
				LocalSet(2),
				LocalGet(2),
				ArrayLen,
				I32Const(1),
				I32Sub,
				LocalSet(3),
				LocalGet(1),
				Call(hash),
				LocalGet(3),
				I32And,
				LocalSet(4),
				Block(null),
				Loop(null),
				LocalGet(2),
				LocalGet(4),
				ArrayGet(indexType),
				LocalSet(5),
				LocalGet(5),
				I32Eqz,
				If(null),
				I32Const(-1),
				Return,
				End
			].concat(keyAt(0, [LocalGet(5), I32Const(1), I32Sub]))
			.concat([LocalGet(1)])
			.concat(stringEqual >= 0 ? [Call(stringEqual)] : [I32Eq])
			.concat([
				If(null),
				LocalGet(4),
				Return,
				End,
				LocalGet(4),
				I32Const(1),
				I32Add,
				LocalGet(3),
				I32And,
				LocalSet(4),
				Br(0),
				End,
				End,
				I32Const(-1),
				Return
			]));
		// find(map, key): the entry position, or -1
		var find = define(prefix + 'find_' + mapName, {parameters: [mapReference, keyValue], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			LocalGet(1),
			Call(findSlot),
			LocalSet(2),
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(I32),
			I32Const(-1),
			Else,
			LocalGet(0),
			StructGet(mapType, 4),
			LocalGet(2),
			ArrayGet(indexType),
			I32Const(1),
			I32Sub,
			End,
			Return
		]);
		// insertSlot(map, key, entry): records the entry in the first free slot of the key's probe run
		var insertSlot = define(prefix + 'insert_slot_' + mapName, {parameters: [mapReference, keyValue, I32], results: []},
			[{type: indexReference}, {type: I32}, {type: I32}], [
				LocalGet(0),
				StructGet(mapType, 4),
				LocalSet(3),
				LocalGet(3),
				ArrayLen,
				I32Const(1),
				I32Sub,
				LocalSet(4),
				LocalGet(1),
				Call(hash),
				LocalGet(4),
				I32And,
				LocalSet(5),
				Block(null),
				Loop(null),
				LocalGet(3),
				LocalGet(5),
				ArrayGet(indexType),
				I32Eqz,
				BrIf(1),
				LocalGet(5),
				I32Const(1),
				I32Add,
				LocalGet(4),
				I32And,
				LocalSet(5),
				Br(0),
				End,
				End,
				LocalGet(3),
				LocalGet(5),
				LocalGet(2),
				I32Const(1),
				I32Add,
				ArraySet(indexType),
				Return
			]);
		// rebuild(map): a fresh index sized for the current capacity, holding every entry
		var rebuild = define(prefix + 'rebuild_' + mapName, {parameters: [mapReference], results: []}, [{type: I32}], [
			LocalGet(0),
			LocalGet(0),
			StructGet(mapType, 1),
			I32Const(1),
			I32Shl,
			ArrayNewDefault(indexType),
			StructSet(mapType, 4),
			I32Const(0),
			LocalSet(1),
			Block(null),
			Loop(null),
			LocalGet(1),
			LocalGet(0),
			StructGet(mapType, 0),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(0)
		].concat(keyAt(0, [LocalGet(1)])).concat([
			LocalGet(1),
			Call(insertSlot),
			LocalGet(1),
			I32Const(1),
			I32Add,
			LocalSet(1),
			Br(0),
			End,
			End,
			Return
			]));
		// removeSlot(map, slot): empties the slot and moves back every later member of its probe run that would
		// otherwise become unreachable
		var removeSlot = define(prefix + 'remove_slot_' + mapName, {parameters: [mapReference, I32], results: []}, [
			{type: indexReference},
			{type: I32},
			{type: I32},
			{type: I32},
			{type: I32},
			{type: I32}
		], [
			LocalGet(0),
			StructGet(mapType, 4),
			LocalSet(2),
			LocalGet(2),
			ArrayLen,
			I32Const(1),
			I32Sub,
			LocalSet(3),
			LocalGet(1),
			LocalSet(4),
			LocalGet(4),
			LocalSet(5),
			Block(null),
			Loop(null),
			LocalGet(5),
			I32Const(1),
			I32Add,
			LocalGet(3),
			I32And,
			LocalSet(5),
			LocalGet(2),
			LocalGet(5),
			ArrayGet(indexType),
			LocalSet(6),
			LocalGet(6),
			I32Eqz,
			BrIf(1)
		].concat(keyAt(0, [LocalGet(6), I32Const(1), I32Sub])).concat([
			Call(hash),
			LocalGet(3),
			I32And,
			LocalSet(7),
			// the member stays when its home slot lies cyclically in (hole, here]
			LocalGet(4),
			LocalGet(5),
			I32LeS,
			If(I32),
			LocalGet(4),
			LocalGet(7),
			I32LtS,
			LocalGet(7),
			LocalGet(5),
			I32LeS,
			I32And,
			Else,
			LocalGet(4),
			LocalGet(7),
			I32LtS,
			LocalGet(7),
			LocalGet(5),
			I32LeS,
			I32Or,
			End,
			I32Eqz,
			If(null),
			LocalGet(2),
			LocalGet(4),
			LocalGet(6),
			ArraySet(indexType),
			LocalGet(5),
			LocalSet(4),
			End,
			Br(0),
			End,
			End,
			LocalGet(2),
			LocalGet(4),
			I32Const(0),
			ArraySet(indexType),
			Return
			]));
		return {
			hash: hash,
			findSlot: findSlot,
			find: find,
			insertSlot: insertSlot,
			rebuild: rebuild,
			removeSlot: removeSlot
		};
	}

	static function ensureStringEqual(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan):Int {
		var name = "__haxeon_gc_bytes_equal", result = functions.get(name);
		if (result != null)
			return result;
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			RefIsNull,
			LocalGet(1),
			RefIsNull,
			I32Or,
			If(I32),
			LocalGet(0),
			LocalGet(1),
			RefEq,
			Else,
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 2),
			LocalSet(2),
			LocalGet(1),
			StructGet(plan.bytesTypeIndex, 2),
			LocalSet(3),
			LocalGet(2),
			LocalGet(3),
			I32Eq,
			LocalSet(5),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			// Unequal lengths end the scan at once, before it can index past the shorter key.
			LocalGet(4),
			LocalGet(2),
			I32LtS,
			LocalGet(5),
			I32And,
			I32Eqz,
			BrIf(1),
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 0),
			LocalGet(0),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(4),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			LocalGet(1),
			StructGet(plan.bytesTypeIndex, 0),
			LocalGet(1),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(4),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			I32Eq,
			I32Eqz,
			If(null),
			I32Const(0),
			LocalSet(5),
			Br(2),
			End,
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(0),
			End,
			End,
			LocalGet(5),
			End,
			Return
		];
		result = module.addFunction(new WasmFunction(name, {parameters: [plan.valueType(Bytes), plan.valueType(Bytes)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
		functions.set(name, result);
		return result;
	}

	static function addAlloc(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType):Int {
		var body:Array<WasmInstruction> = [I32Const(0), I32Const(8)];
		appendNewArray(body, plan, map.keyType, [I32Const(8)]);
		appendNewArray(body, plan, map.valueType, [I32Const(8)]);
		// twice the capacity, a power of two, so the index is never more than half full
		body = body.concat([
			I32Const(16),
			ArrayNewDefault(plan.mapIndexTypeIndex),
			StructNew(mapType),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [], results: [mapReference]}, [], body));
	}

	static function addSet(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType,
			helpers:WasmGcMapHelpers):Int {
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			keyStorage = plan.arrayStorageType(map.keyType),
			valueStorage = plan.arrayStorageType(map.valueType),
			indexType = plan.mapIndexTypeIndex, // slot 3, entry 4, new capacity 5, new key array 6, new value array 7
			body:Array<WasmInstruction> = [
				LocalGet(0),
				LocalGet(1),
				Call(helpers.findSlot),
				LocalSet(3),
				LocalGet(3),
				I32Const(0),
				I32LtS,
				If(null),
				LocalGet(0),
				StructGet(mapType, 0),
				LocalSet(4),
				LocalGet(4),
				LocalGet(0),
				StructGet(mapType, 1),
				I32Eq,
				If(null),
				LocalGet(0),
				StructGet(mapType, 1),
				I32Const(2),
				I32Mul,
				LocalSet(5)
			];
		appendNewArray(body, plan, map.keyType, [LocalGet(5)]);
		body.push(LocalSet(6));
		appendNewArray(body, plan, map.valueType, [LocalGet(5)]);
		body.push(LocalSet(7));
		appendArrayCopy(body, keyStorage, [
			LocalGet(6),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(keyStorage)})
		], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(keyStorage)})
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		appendArrayCopy(body, valueStorage, [
			LocalGet(7),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(valueStorage)})
		], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(valueStorage)})
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		body = body.concat([
			LocalGet(0),
			LocalGet(5),
			StructSet(mapType, 1),
			LocalGet(0),
			LocalGet(6),
			StructSet(mapType, 2),
			LocalGet(0),
			LocalGet(7),
			StructSet(mapType, 3),
			// the larger arrays need a larger index, holding the entries already there
			LocalGet(0),
			Call(helpers.rebuild),
			End,
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(keyStorage)}),
			LocalGet(4),
			LocalGet(1),
			ArraySet(keyStorage),
			LocalGet(0),
			LocalGet(0),
			StructGet(mapType, 0),
			I32Const(1),
			I32Add,
			StructSet(mapType, 0),
			LocalGet(0),
			LocalGet(1),
			LocalGet(4),
			Call(helpers.insertSlot),
			Else,
			LocalGet(0),
			StructGet(mapType, 4),
			LocalGet(3),
			ArrayGet(indexType),
			I32Const(1),
			I32Sub,
			LocalSet(4),
			End,
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({
				nullable: false,
				heap: Type(valueStorage)
			}),
			LocalGet(4),
			LocalGet(2),
			ArraySet(valueStorage),
			Return
		]);
		return module.addFunction(new WasmFunction(name,
			{parameters: [mapReference, plan.valueType(map.keyType), plan.valueType(map.valueType)], results: []}, [
			{type: I32},
			{type: I32},
			{type: I32},
			{type: Ref({nullable: false, heap: Type(keyArray)})},
			{type: Ref({nullable: false, heap: Type(valueArray)})}
		], body));
	}

	static function addExists(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType, find:Int):Int
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference, plan.valueType(map.keyType)], results: [I32]}, [],
			[LocalGet(0), LocalGet(1), Call(find), I32Const(-1), I32Eq, I32Eqz, Return]));

	static function addGet(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType, find:Int):Int {
		var valueArray = plan.arrayType(map.valueType),
			valueStorage = plan.arrayStorageType(map.valueType),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				LocalGet(1),
				Call(find),
				LocalSet(2),
				LocalGet(2),
				I32Const(-1),
				I32Eq,
				If(null),
				RefNull(Any),
				Return,
				End,
				LocalGet(0),
				StructGet(mapType, 3),
				StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({
					nullable: false,
					heap: Type(valueStorage)
				}),
				LocalGet(2),
				ArrayGet(valueStorage)
			],
			resultType:WasmValueType = Ref({
				nullable: true,
				heap: Any
			});
		if (map.valueType == I32 || map.valueType == Bool || map.valueType == I64 || map.valueType == F64)
			body.push(StructNew(plan.boxedPrimitiveType(map.valueType)));
		body.push(Return);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference, plan.valueType(map.keyType)], results: [resultType]}, [{type: I32}],
			body));
	}

	/** A new map with the same entries: arrays of the source's capacity, the used prefix copied, no rehash. */
	static function addCopy(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType):Int {
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			keyStorage = plan.arrayStorageType(map.keyType),
			valueStorage = plan.arrayStorageType(map.valueType),
			body:Array<WasmInstruction> = [];
		appendNewArray(body, plan, map.keyType, [LocalGet(0), StructGet(mapType, 1)]);
		body.push(LocalSet(1));
		appendNewArray(body, plan, map.valueType, [LocalGet(0), StructGet(mapType, 1)]);
		body.push(LocalSet(2));
		appendArrayCopy(body, keyStorage, [
			LocalGet(1),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(keyStorage)})
		], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(keyStorage)})
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		appendArrayCopy(body, valueStorage, [
			LocalGet(2),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(valueStorage)})
		], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(valueStorage)})
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		var indexType = plan.mapIndexTypeIndex;
		body = body.concat([
			LocalGet(0),
			StructGet(mapType, 4),
			ArrayLen,
			ArrayNewDefault(indexType),
			LocalSet(3),
			LocalGet(3),
			I32Const(0),
			LocalGet(0),
			StructGet(mapType, 4),
			I32Const(0),
			LocalGet(0),
			StructGet(mapType, 4),
			ArrayLen,
			ArrayCopy(indexType, indexType),
			LocalGet(0),
			StructGet(mapType, 0),
			LocalGet(0),
			StructGet(mapType, 1),
			LocalGet(1),
			LocalGet(2),
			LocalGet(3),
			StructNew(mapType),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference], results: [mapReference]}, [
			{type: Ref({nullable: false, heap: Type(keyArray)})},
			{type: Ref({nullable: false, heap: Type(valueArray)})},
			{type: Ref({nullable: false, heap: Type(indexType)})}
		], body));
	}

	static function addClear(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType):Int {
		var body:Array<WasmInstruction> = [
			I32Const(0),
			LocalSet(1),
			Block(null),
			Loop(null),
			LocalGet(1),
			LocalGet(0),
			StructGet(mapType, 0),
			I32LtS,
			I32Eqz,
			BrIf(1)
		];
		appendMapArrayDefault(body, plan, mapType, 2, map.keyType, [LocalGet(1)]);
		appendMapArrayDefault(body, plan, mapType, 3, map.valueType, [LocalGet(1)]);
		body = body.concat([
			LocalGet(1),
			I32Const(1),
			I32Add,
			LocalSet(1),
			Br(0),
			End,
			End,
			LocalGet(0),
			I32Const(0),
			StructSet(mapType, 0),
			// an index of the same length with every slot empty
			LocalGet(0),
			LocalGet(0),
			StructGet(mapType, 4),
			ArrayLen,
			ArrayNewDefault(plan.mapIndexTypeIndex),
			StructSet(mapType, 4),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference], results: []}, [{type: I32}], body));
	}

	static function addProjectionForNative(module:WasmModule, name:String, plan:WasmGcTypePlan, native:IrNative, map:WasmGcMapTypePlan, mapType:Int,
			mapReference:WasmValueType, keys:Bool):Int {
		return addProjection(module, name, plan, map, mapType, mapReference, native.result, keys);
	}

	static function addProjection(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType,
			outputType:IrType, keys:Bool):Int {
		var element = switch outputType {
			case Array(element): element;
			default: throw 'Wasm GC map projection $name must return an array';
		}, sourceElement = keys ? map.keyType : map.valueType, array = plan.arrayType(element), storage = plan.arrayStorageType(element), sourceArray = plan.arrayType(sourceElement), sourceStorage = plan.arrayStorageType(sourceElement), mapField = keys ? 2 : 3, body:Array<WasmInstruction> = [
			LocalGet(0),
			StructGet(mapType, 0),
			LocalGet(0),
			StructGet(mapType, 0),
			I32Const(8),
			I32Add,
			ArrayNewDefault(storage),
			I32Const(WasmModuleSupport.typeId(element)),
			StructNew(array),
			LocalSet(1)
			];
		if (sourceElement == element) {
			appendArrayCopy(body, storage, [
				LocalGet(1),
				StructGet(array, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(storage)})
			], [I32Const(0)], [
				LocalGet(0),
				StructGet(mapType, mapField),
				StructGet(sourceArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(sourceStorage)})
			], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		} else {
			var targetReference = switch plan.valueType(element) {
				case Ref(reference): reference;
				default: throw 'Wasm GC map projection $name changes between incompatible storage types';
			};
			body = body.concat([
				I32Const(0),
				LocalSet(2),
				Block(null),
				Loop(null),
				LocalGet(2),
				LocalGet(0),
				StructGet(mapType, 0),
				I32LtS,
				I32Eqz,
				BrIf(1),
				LocalGet(1),
				StructGet(array, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({
					nullable: false,
					heap: Type(storage)
				}),
				LocalGet(2),
				LocalGet(0),
				StructGet(mapType, mapField),
				StructGet(sourceArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(sourceStorage)}),
				LocalGet(2),
				ArrayGet(sourceStorage),
				RefCast(targetReference),
				ArraySet(storage),
				LocalGet(2),
				I32Const(1),
				I32Add,
				LocalSet(2),
				Br(0),
				End,
				End
			]);
		}
		body = body.concat([LocalGet(1), Return]);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference], results: [plan.valueType(outputType)]},
			[{type: Ref({nullable: false, heap: Type(array)})}, {type: I32}], body));
	}

	static function addRemove(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType,
			helpers:WasmGcMapHelpers):Int {
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			keyStorage = plan.arrayStorageType(map.keyType),
			valueStorage = plan.arrayStorageType(map.valueType),
			indexType = plan.mapIndexTypeIndex;
		function keyData():Array<WasmInstruction>
			return [
				LocalGet(0),
				StructGet(mapType, 2),
				StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(keyStorage)})
			];
		function valueData():Array<WasmInstruction>
			return [
				LocalGet(0),
				StructGet(mapType, 3),
				StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
				RefCast({nullable: false, heap: Type(valueStorage)})
			];
		// slot 2, removed entry 3, last entry 4, slot of the last entry's key 5. The last entry takes the removed
		// one's place, so removal is constant time and the entry arrays stay dense.
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			LocalGet(1),
			Call(helpers.findSlot),
			LocalSet(2),
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(I32),
			I32Const(0),
			Else,
			LocalGet(0),
			StructGet(mapType, 4),
			LocalGet(2),
			ArrayGet(indexType),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			LocalGet(0),
			StructGet(mapType, 0),
			I32Const(1),
			I32Sub,
			LocalSet(4),
			LocalGet(0),
			LocalGet(2),
			Call(helpers.removeSlot),
			LocalGet(3),
			LocalGet(4),
			I32Eq,
			I32Eqz,
			If(null),
			LocalGet(0)
		];
		body = body.concat(keyData()).concat([
			LocalGet(4),
			ArrayGet(keyStorage),
			Call(helpers.findSlot),
			LocalSet(5),
			LocalGet(0),
			StructGet(mapType, 4),
			LocalGet(5),
			LocalGet(3),
			I32Const(1),
			I32Add,
			ArraySet(indexType)
		]);
		body = body.concat(keyData())
			.concat([LocalGet(3)])
			.concat(keyData())
			.concat([LocalGet(4), ArrayGet(keyStorage), ArraySet(keyStorage)]);
		body = body.concat(valueData())
			.concat([LocalGet(3)])
			.concat(valueData())
			.concat([LocalGet(4), ArrayGet(valueStorage), ArraySet(valueStorage)]);
		body.push(End);
		appendMapArrayDefault(body, plan, mapType, 2, map.keyType, [LocalGet(4)]);
		appendMapArrayDefault(body, plan, mapType, 3, map.valueType, [LocalGet(4)]);
		body = body.concat([LocalGet(0), LocalGet(4), StructSet(mapType, 0), I32Const(1), End, Return]);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference, plan.valueType(map.keyType)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function appendMapArrayDefault(body:Array<WasmInstruction>, plan:WasmGcTypePlan, mapType:Int, mapField:Int, element:IrType,
			index:Array<WasmInstruction>):Void {
		var arrayType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element);
		body.push(LocalGet(0));
		body.push(StructGet(mapType, mapField));
		body.push(StructGet(arrayType, WasmGcTypePlan.arrayDataFieldIndex()));
		body.push(RefCast({nullable: false, heap: Type(storageType)}));
		for (instruction in index)
			body.push(instruction);
		switch plan.valueType(element) {
			case I32:
				body.push(I32Const(0));
			case I64:
				body.push(I64Const(0));
			case F64:
				body.push(F64Const(0));
			case Ref(reference):
				body.push(RefNull(reference.heap));
			case F32:
				throw 'Unsupported f32 Wasm GC map element $element';
		}
		body.push(ArraySet(storageType));
	}

	static function appendNewArray(body:Array<WasmInstruction>, plan:WasmGcTypePlan, element:IrType, capacity:Array<WasmInstruction>):Void {
		for (instruction in capacity)
			body.push(instruction);
		for (instruction in capacity)
			body.push(instruction);
		body.push(I32Const(8));
		body.push(I32Add);
		body.push(ArrayNewDefault(plan.arrayStorageType(element)));
		body.push(I32Const(WasmModuleSupport.typeId(element)));
		body.push(StructNew(plan.arrayType(element)));
	}

	static function appendArrayCopy(body:Array<WasmInstruction>, storage:Int, destination:Array<WasmInstruction>, destinationIndex:Array<WasmInstruction>,
			source:Array<WasmInstruction>, sourceIndex:Array<WasmInstruction>, length:Array<WasmInstruction>):Void {
		for (instruction in destination)
			body.push(instruction);
		for (instruction in destinationIndex)
			body.push(instruction);
		for (instruction in source)
			body.push(instruction);
		for (instruction in sourceIndex)
			body.push(instruction);
		for (instruction in length)
			body.push(instruction);
		body.push(ArrayCopy(storage, storage));
	}
}
