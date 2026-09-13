package compiler.backend.wasm;

import compiler.backend.wasm.WasmGcTypePlan.WasmGcMapTypePlan;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;

/** Lowers specialized Haxe maps to GC structs containing typed GC arrays. */
class WasmGcMaps {
	public static function add(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, native:IrNative, mapName:String, operation:String):Int {
		var map = plan.mapPlan(mapName),
			mapType = plan.mapType(mapName),
			mapReference = Ref({nullable: true, heap: Type(mapType)}),
			name = '__${mapName}_$operation';
		return switch operation {
			case "alloc": addAlloc(module, name, plan, map, mapType, mapReference);
			case "set": addSet(module, name, plan, map, mapType, mapReference, ensureFind(module, functions, plan, mapName));
			case "exists": addExists(module, name, plan, map, mapType, mapReference, ensureFind(module, functions, plan, mapName));
			case "get": addGet(module, name, plan, map, mapType, mapReference, ensureFind(module, functions, plan, mapName));
			case "keys": addProjectionForNative(module, name, plan, native, map, mapType, mapReference, true);
			case "values": addProjectionForNative(module, name, plan, native, map, mapType, mapReference, false);
			case "remove": addRemove(module, name, plan, map, mapType, mapReference, ensureFind(module, functions, plan, mapName));
			case "clear": addClear(module, name, plan, map, mapType, mapReference);
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

	static function ensureFind(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, mapName:String):Int {
		var name = '__haxeon_gc_map_find_$mapName',
			result = functions.get(name);
		if (result != null)
			return result;
		var map = plan.mapPlan(mapName),
			mapType = plan.mapType(mapName),
			mapReference = Ref({nullable: true, heap: Type(mapType)}),
			keyType = plan.arrayType(map.keyType),
			keyStorage = plan.arrayStorageType(map.keyType),
			stringEqual = map.keyType == Bytes ? ensureStringEqual(module, functions, plan) : -1,
			body:Array<WasmInstruction> = [
				I32Const(0),
				LocalSet(2),
				Block(null),
				Loop(null),
				LocalGet(2),
				LocalGet(0),
				StructGet(mapType, 0),
				I32LtS,
				If(null),
				LocalGet(0),
				StructGet(mapType, 2),
				StructGet(keyType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalGet(2),
				ArrayGet(keyStorage)
			];
		if (stringEqual >= 0)
			body = body.concat([LocalGet(1), Call(stringEqual)]);
		else
			body = body.concat([LocalGet(1), I32Eq]);
		body = body.concat([
			If(null),
			LocalGet(2),
			Return,
			End,
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			I32Const(-1),
			Return
		]);
		result = module.addFunction(new WasmFunction(name, {parameters: [mapReference, plan.valueType(map.keyType)], results: [I32]}, [{type: I32}], body));
		functions.set(name, result);
		return result;
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
			LocalGet(4),
			LocalGet(2),
			I32LtS,
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
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			body:Array<WasmInstruction> = [I32Const(0), I32Const(8)];
		appendNewArray(body, plan, map.keyType, [I32Const(8)]);
		appendNewArray(body, plan, map.valueType, [I32Const(8)]);
		body = body.concat([StructNew(mapType), Return]);
		return module.addFunction(new WasmFunction(name, {parameters: [], results: [mapReference]}, [], body));
	}

	static function addSet(module:WasmModule, name:String, plan:WasmGcTypePlan, map:WasmGcMapTypePlan, mapType:Int, mapReference:WasmValueType, find:Int):Int {
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			keyStorage = plan.arrayStorageType(map.keyType),
			valueStorage = plan.arrayStorageType(map.valueType),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				LocalGet(1),
				Call(find),
				LocalSet(3),
				LocalGet(3),
				I32Const(-1),
				I32Eq,
				If(null),
				LocalGet(0),
				StructGet(mapType, 0),
				LocalSet(3),
				LocalGet(0),
				StructGet(mapType, 0),
				LocalGet(0),
				StructGet(mapType, 1),
				I32Eq,
				If(null),
				LocalGet(0),
				StructGet(mapType, 1),
				I32Const(2),
				I32Mul,
				LocalSet(4)
			];
		appendNewArray(body, plan, map.keyType, [LocalGet(4)]);
		body.push(LocalSet(5));
		appendNewArray(body, plan, map.valueType, [LocalGet(4)]);
		body.push(LocalSet(6));
		appendArrayCopy(body, keyStorage, [LocalGet(5), StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex())], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		appendArrayCopy(body, valueStorage, [LocalGet(6), StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex())], [I32Const(0)], [
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [I32Const(0)], [LocalGet(0), StructGet(mapType, 0)]);
		body = body.concat([
			LocalGet(0),
			LocalGet(4),
			StructSet(mapType, 1),
			LocalGet(0),
			LocalGet(5),
			StructSet(mapType, 2),
			LocalGet(0),
			LocalGet(6),
			StructSet(mapType, 3),
			End,
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(3),
			LocalGet(1),
			ArraySet(keyStorage),
			LocalGet(0),
			LocalGet(0),
			StructGet(mapType, 0),
			I32Const(1),
			I32Add,
			StructSet(mapType, 0),
			End,
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(3),
			LocalGet(2),
			ArraySet(valueStorage),
			Return
		]);
		return module.addFunction(new WasmFunction(name,
			{parameters: [mapReference, plan.valueType(map.keyType), plan.valueType(map.valueType)], results: []}, [
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
			StructNew(array),
			LocalSet(1)
			];
		if (sourceElement == element) {
			appendArrayCopy(body, storage, [LocalGet(1), StructGet(array, WasmGcTypePlan.arrayDataFieldIndex())], [I32Const(0)], [
				LocalGet(0),
				StructGet(mapType, mapField),
				StructGet(sourceArray, WasmGcTypePlan.arrayDataFieldIndex())
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
				LocalGet(2),
				LocalGet(0),
				StructGet(mapType, mapField),
				StructGet(sourceArray, WasmGcTypePlan.arrayDataFieldIndex()),
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
			find:Int):Int {
		var keyArray = plan.arrayType(map.keyType),
			valueArray = plan.arrayType(map.valueType),
			keyStorage = plan.arrayStorageType(map.keyType),
			valueStorage = plan.arrayStorageType(map.valueType),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				LocalGet(1),
				Call(find),
				LocalSet(2),
				LocalGet(2),
				I32Const(-1),
				I32Eq,
				If(I32),
				I32Const(0),
				Else,
				LocalGet(0),
				StructGet(mapType, 0),
				LocalSet(3),
				LocalGet(3),
				LocalGet(2),
				I32Sub,
				I32Const(1),
				I32Sub,
				LocalSet(4)
			];
		appendArrayCopy(body, keyStorage, [
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [LocalGet(2)], [
			LocalGet(0),
			StructGet(mapType, 2),
			StructGet(keyArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [LocalGet(2), I32Const(1), I32Add], [LocalGet(4)]);
		appendArrayCopy(body, valueStorage, [
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [LocalGet(2)], [
			LocalGet(0),
			StructGet(mapType, 3),
			StructGet(valueArray, WasmGcTypePlan.arrayDataFieldIndex())
		], [LocalGet(2), I32Const(1), I32Add], [LocalGet(4)]);
		appendMapArrayDefault(body, plan, mapType, 2, map.keyType, [LocalGet(3), I32Const(1), I32Sub]);
		appendMapArrayDefault(body, plan, mapType, 3, map.valueType, [LocalGet(3), I32Const(1), I32Sub]);
		body = body.concat([
			LocalGet(0),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			StructSet(mapType, 0),
			I32Const(1),
			End,
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [mapReference, plan.valueType(map.keyType)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}], body));
	}

	static function appendMapArrayDefault(body:Array<WasmInstruction>, plan:WasmGcTypePlan, mapType:Int, mapField:Int, element:IrType,
			index:Array<WasmInstruction>):Void {
		var arrayType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element);
		body.push(LocalGet(0));
		body.push(StructGet(mapType, mapField));
		body.push(StructGet(arrayType, WasmGcTypePlan.arrayDataFieldIndex()));
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
