package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmRepresentation.WasmAggregateRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmInteropRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmRepresentation.WasmValueRepresentation;

/** Linear32 representation: managed references remain i32 pointers into the custom heap. */
class WasmLinearRepresentation implements WasmValueRepresentation implements WasmAggregateRepresentation implements WasmInteropRepresentation {
	final layout:WasmLayout;
	final allocator:Int;
	final bytesDataPointer:Int;

	public function new(layout:WasmLayout, allocator:Int, bytesDataPointer:Int) {
		this.layout = layout;
		this.allocator = allocator;
		this.bytesDataPointer = bytesDataPointer;
	}

	public function valueType(type:IrType):WasmValueType
		return WasmModuleSupport.requireValueType(type);

	public function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F32 | F64: [F64Const(0)];
			case Void: [];
			default: [I32Const(0)];
		};

	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>
		return [I32Const(0), LocalSet(destination)];

	public function constantString(value:String, destination:Int, strings:Map<String, Int>):WasmLoweringResult
		return UseDefault;

	public function newObject(typeName:String, destination:Int):Array<WasmInstruction> {
		return [
			I32Const(layout.object(typeName).size),
			Call(allocator),
			LocalTee(destination),
			I32Const(WasmModuleSupport.typeId(Obj(typeName))),
			I32Store(0)
		];
	}

	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var field = objectField(object, fieldName);
		return [LocalGet(objectLocal), load(field.type, field.offset), LocalSet(destination)];
	}

	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var field = objectField(object, fieldName);
		return [LocalGet(objectLocal), LocalGet(valueLocal), store(field.type, field.offset)];
	}

	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		var instruction = switch left.type {
			case I64: I64Eq;
			case F32 | F64: F64Eq;
			default: I32Eq;
		};
		return [LocalGet(leftLocal), LocalGet(rightLocal), instruction, LocalSet(output)];
	}

	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):WasmLoweringResult
		return UseDefault;

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>):WasmLoweringResult {
		if (name == "__wasm_memory_load_i32") {
			if (output.type != I32 || arguments.length != 1 || arguments[0].type != I32 || argumentLocals.length != 1)
				throw "Invalid Wasm runtime memory.load i32 signature";
			return [LocalGet(argumentLocals[0]), I32Load(0), LocalSet(outputLocal)];
		}
		if (name == "__f64_to_i64_bits" || name == "runtime.FloatBits.toInt64") {
			if (output.type != I64 || arguments.length != 1 || arguments[0].type != F64 || argumentLocals.length != 1)
				throw "Invalid Wasm FloatBits.toInt64 signature";
			return [LocalGet(argumentLocals[0]), I64ReinterpretF64, LocalSet(outputLocal)];
		}
		if (name == "__i64_to_f64_bits" || name == "runtime.FloatBits.fromInt64") {
			if (output.type != F64 || arguments.length != 1 || arguments[0].type != I64 || argumentLocals.length != 1)
				throw "Invalid Wasm FloatBits.fromInt64 signature";
			return [LocalGet(argumentLocals[0]), F64ReinterpretI64, LocalSet(outputLocal)];
		}
		return UseDefault;
	}

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):WasmLoweringResult {
		var fixed = native.fixedResult;
		if (fixed == null)
			return UseDefault;
		if (native.result != ManagedBytes || outputLocal < 0)
			throw 'Linear Wasm C native "${native.name}" has an invalid fixed aggregate result contract';
		var body:Array<WasmInstruction> = [],
			allocationSize = WasmLayout.STRING_DATA_OFFSET + fixed.size;
		// Linear Wasm C-native imports return a pointer to the raw aggregate. Materialize
		// that pointer as a managed Bytes value before the generated HXI wrapper attaches
		// the projected fixed-layout record to it.
		body.push(I32Const(allocationSize));
		body.push(Call(allocator));
		body.push(LocalSet(outputLocal));
		for (field in [
			{offset: 0, value: WasmModuleSupport.typeId(Bytes)},
			{offset: WasmLayout.STRING_LENGTH_OFFSET, value: fixed.size},
			{offset: WasmLayout.ARRAY_CAPACITY_OFFSET, value: fixed.size}
		]) {
			body.push(LocalGet(outputLocal));
			body.push(I32Const(field.value));
			body.push(I32Store(field.offset));
		}
		body.push(LocalGet(outputLocal));
		body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
		body.push(I32Add);
		for (index in 0...arguments.length)
			nativeArgument(body, arguments[index], argumentLocals[index]);
		body.push(Call(importIndex));
		body.push(I32Const(fixed.size));
		body.push(MemoryCopy);
		return body;
	}

	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):WasmLoweringResult
		return UseDefault;

	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult
		return UseDefault;

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int, argumentLocals:Array<Int>):WasmLoweringResult
		return UseDefault;

	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	function objectField(object:IrValue, name:String):WasmFieldLayout {
		return switch object.type {
			case Obj(objectName): layout.field(objectName, name);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};
	}

	static function load(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Load(offset);
			case F32 | F64: F64Load(offset);
			default: I32Load(offset);
		};

	static function store(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Store(offset);
			case F32 | F64: F64Store(offset);
			default: I32Store(offset);
		};

	function nativeArgument(body:Array<WasmInstruction>, argument:IrValue, argumentLocal:Int):Void {
		body.push(LocalGet(argumentLocal));
		switch argument.type {
			case Bytes, ManagedBytes:
				body.push(Call(bytesDataPointer));
			case Abstract("realtime_bytes"):
				body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
				body.push(I32Add);
			case _:
		}
	}
}
