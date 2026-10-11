package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmCAbi;
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
	final cstringCopy:Int;

	public function new(layout:WasmLayout, allocator:Int, bytesDataPointer:Int, cstringCopy:Int) {
		this.layout = layout;
		this.allocator = allocator;
		this.bytesDataPointer = bytesDataPointer;
		this.cstringCopy = cstringCopy;
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
		var object = layout.object(typeName),
			nativeLayout = object.nativeLayout,
			body:Array<WasmInstruction> = [I32Const(layout.object(typeName).size), Call(allocator), LocalSet(destination)];
		if (nativeLayout != null)
			body = body.concat([
				LocalGet(destination),
				I32Const(0),
				I32Const(nativeLayout.size + WasmLayout.FLAT_HEADER_SIZE),
				MemoryFill
			]);
		body = body.concat([
			LocalGet(destination),
			I32Const(WasmModuleSupport.typeId(Obj(typeName))),
			I32Store(0)
		]);
		return body;
	}

	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var field = objectField(object, fieldName);
		if (field.nativeLayout != null) {
			if (field.nativeLayout.inlineRecord)
				return inlineRecordGet(field, destination, objectLocal);
			return nativeFieldGet(field, destination, objectLocal);
		}
		return [LocalGet(objectLocal), load(field.type, field.offset), LocalSet(destination)];
	}

	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var field = objectField(object, fieldName);
		if (field.nativeLayout != null) {
			if (field.nativeLayout.inlineRecord)
				return inlineRecordSet(field, objectLocal, valueLocal);
			return nativeFieldSet(field, objectLocal, valueLocal);
		}
		return [LocalGet(objectLocal), LocalGet(valueLocal), store(field.type, field.offset)];
	}

	function nativeFieldGet(field:WasmFieldLayout, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Flat Wasm field "${field.name}" is missing layout metadata';
		var body = flatFieldBase(objectLocal, native.offset),
			load:Array<WasmInstruction> = [];
		if (field.type == I32 && native.size == 1)
			load = [native.signed ? I32Load8S(0) : I32Load8U(0)];
		else if (field.type == Bool && native.size == 1)
			load = [I32Load8U(0)];
		else if (field.type == I32 && native.size == 2)
			load = [native.signed ? I32Load16S(0) : I32Load16U(0)];
		else if (field.type == I64 && native.size == 4)
			load = [I32Load(0), native.signed ? I64ExtendI32S : I64ExtendI32U];
		else if (field.type == F32 && native.size == 4)
			load = [F32Load(0), F64PromoteF32];
		else if ((field.type == I32 || field.type == Bool || field.type == RawPtr) && native.size == 4)
			load = [I32Load(0)];
		else if (field.type == I64 && native.size == 8)
			load = [I64Load(0)];
		else if (field.type == F64 && native.size == 8)
			load = [F64Load(0)];
		else
			throw 'Unsupported flat Wasm field storage ${native.size} bytes for ${Std.string(field.type)}';
		return body.concat(load).concat([LocalSet(destination)]);
	}

	function nativeFieldSet(field:WasmFieldLayout, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Flat Wasm field "${field.name}" is missing layout metadata';
		var body:Array<WasmInstruction> = flatFieldBase(objectLocal, native.offset).concat([LocalGet(valueLocal)]);
		if ((field.type == I32 || field.type == Bool) && native.size == 1)
			body.push(I32Store8(0));
		else if (field.type == I32 && native.size == 2)
			body.push(I32Store16(0));
		else if (field.type == I64 && native.size == 4)
			body = body.concat([I32WrapI64, I32Store(0)]);
		else if (field.type == F32 && native.size == 4)
			body = body.concat([F32DemoteF64, F32Store(0)]);
		else if ((field.type == I32 || field.type == Bool || field.type == RawPtr) && native.size == 4)
			body.push(I32Store(0));
		else if (field.type == I64 && native.size == 8)
			body.push(I64Store(0));
		else if (field.type == F64 && native.size == 8)
			body.push(F64Store(0));
		else
			throw 'Unsupported flat Wasm field storage ${native.size} bytes for ${Std.string(field.type)}';
		return body;
	}

	function inlineRecordGet(field:WasmFieldLayout, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Inline flat Wasm field "${field.name}" is missing layout metadata';
		var childName = switch field.type {
			case Obj(name): name;
			case _: throw 'Inline flat Wasm field "${field.name}" is not a source struct';
		};
		var body = newObject(childName, destination);
		body.push(LocalGet(destination));
		body = body.concat(flatViewOwner(objectLocal));
		body.push(I32Store(4));
		body.push(LocalGet(destination));
		body = body.concat(flatViewOffset(objectLocal, native.offset));
		body.push(I32Store(8));
		return body;
	}

	function inlineRecordSet(field:WasmFieldLayout, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Inline flat Wasm field "${field.name}" is missing layout metadata';
		var body:Array<WasmInstruction> = [];
		for (offset in 0...native.size) {
			body = body.concat(flatFieldBase(objectLocal, native.offset));
			body = body.concat(flatFieldBase(valueLocal, 0));
			body = body.concat([I32Load8U(offset), I32Store8(offset)]);
		}
		return body;
	}

	function flatFieldBase(objectLocal:Int, fieldOffset:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(4),
			LocalGet(objectLocal),
			I32Load(8),
			I32Add,
			Else,
			LocalGet(objectLocal),
			End,
			I32Const(WasmLayout.FLAT_HEADER_SIZE),
			I32Add,
			I32Const(fieldOffset),
			I32Add
		];
	}

	function flatViewOwner(objectLocal:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(4),
			Else,
			LocalGet(objectLocal),
			End
		];
	}

	function flatViewOffset(objectLocal:Int, fieldOffset:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(8),
			Else,
			I32Const(0),
			End,
			I32Const(fieldOffset),
			I32Add
		];
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
		if (name == "__int64_to_float") {
			if (output.type != F64 || arguments.length != 1 || arguments[0].type != I64 || argumentLocals.length != 1)
				throw "Invalid Wasm Int64.toFloat signature";
			return [LocalGet(argumentLocals[0]), F64ConvertI64S, LocalSet(outputLocal)];
		}
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
		var abi = WasmCAbi.of(native), fixed = native.fixedResult;
		if (!abi.adjustsCall() && native.result != Bytes)
			return UseDefault;
		var body:Array<WasmInstruction> = [];
		if (fixed == null) {
			pushNativeArguments(body, abi, arguments, argumentLocals);
			body.push(Call(importIndex));
			body = body.concat(abi.raiseResult());
			if (native.result == Bytes)
				body.push(Call(cstringCopy));
			if (outputLocal >= 0)
				body.push(LocalSet(outputLocal));
			return body;
		}
		if (native.result != ManagedBytes || outputLocal < 0)
			throw 'Linear Wasm C native "${native.name}" has an invalid fixed aggregate result contract';
		var allocationSize = WasmLayout.STRING_DATA_OFFSET + fixed.size;
		// The record result lands in a managed Bytes value that the generated HXI wrapper then attaches the
		// projected fixed-layout record to. The native either returns its single scalar, stored here, or
		// writes the record through the pointer it receives first.
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
		pushNativeArguments(body, abi, arguments, argumentLocals);
		body.push(Call(importIndex));
		if (abi.directResult != null)
			body.push(abi.directResult.store);
		return body;
	}

	function pushNativeArguments(body:Array<WasmInstruction>, abi:WasmCAbi, arguments:Array<IrValue>, argumentLocals:Array<Int>):Void {
		for (index in 0...arguments.length) {
			nativeArgument(body, arguments[index], argumentLocals[index]);
			for (instruction in abi.lowerArgument(index))
				body.push(instruction);
		}
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
