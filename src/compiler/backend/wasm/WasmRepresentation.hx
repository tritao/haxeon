package compiler.backend.wasm;

import haxe.io.Bytes as HaxeBytes;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Operations whose representation differs between linear pointers and Wasm references. */
interface WasmRepresentation {
	public function valueType(type:IrType):WasmValueType;
	public function zeroValue(type:IrType):Array<WasmInstruction>;
	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>;
	public function constantString(value:String, destination:Int, strings:Map<String, Int>):Null<Array<WasmInstruction>>;
	public function newObject(typeName:String, destination:Int):Array<WasmInstruction>;
	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction>;
	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction>;
	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction>;
	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):Null<Array<WasmInstruction>>;
	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{typeName:String, functionIndex:Int}>,
		receiverLocal:Int, destination:Int, argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
	public function beginFunction(allocateLocal:WasmValueType->Int, exceptionTag:Null<Int>):Void;
	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>,
		importIndex:Int):Null<Array<WasmInstruction>>;
	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):Null<Array<WasmInstruction>>;
	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>>;
	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>>;
	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>>;
	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>>;
	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>;
	public function staticClosure(name:String, tableSlots:Map<String, Int>, destination:Int):Null<Array<WasmInstruction>>;
	public function instanceClosure(name:String, tableSlots:Map<String, Int>, receiverLocal:Int, destination:Int):Null<Array<WasmInstruction>>;
	public function callClosure(staticType:Int, instanceType:Null<Int>, arguments:Array<IrValue>, closureLocal:Int, destination:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
}

/** Linear32 representation: managed references remain i32 pointers into the custom heap. */
class WasmLinearRepresentation implements WasmRepresentation {
	final layout:WasmLayout;
	final allocator:Int;

	public function new(layout:WasmLayout, allocator:Int) {
		this.layout = layout;
		this.allocator = allocator;
	}

	public function valueType(type:IrType):WasmValueType
		return WasmBackend.requireValueType(type);

	public function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F64: [F64Const(0)];
			case Void: [];
			default: [I32Const(0)];
		};

	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>
		return [I32Const(0), LocalSet(destination)];

	public function constantString(value:String, destination:Int, strings:Map<String, Int>):Null<Array<WasmInstruction>>
		return null;

	public function newObject(typeName:String, destination:Int):Array<WasmInstruction> {
		return [
			I32Const(layout.object(typeName).size),
			Call(allocator),
			LocalTee(destination),
			I32Const(WasmBackend.typeId(Obj(typeName))),
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

	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		var instruction = switch left.type {
			case I64: I64Eq;
			case F64: F64Eq;
			default: I32Eq;
		};
		return [LocalGet(leftLocal), LocalGet(rightLocal), instruction, LocalSet(output)];
	}

	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{typeName:String, functionIndex:Int}>,
			receiverLocal:Int, destination:Int, argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	public function beginFunction(allocateLocal:WasmValueType->Int, exceptionTag:Null<Int>):Void {}

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>,
			importIndex:Int):Null<Array<WasmInstruction>>
		return null;

	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return null;

	public function staticClosure(name:String, tableSlots:Map<String, Int>, destination:Int):Null<Array<WasmInstruction>>
		return null;

	public function instanceClosure(name:String, tableSlots:Map<String, Int>, receiverLocal:Int, destination:Int):Null<Array<WasmInstruction>>
		return null;

	public function callClosure(staticType:Int, instanceType:Null<Int>, arguments:Array<IrValue>, closureLocal:Int, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	function objectField(object:IrValue, name:String):WasmFieldLayout {
		return switch object.type {
			case Obj(objectName): layout.field(objectName, name);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};
	}

	static function load(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Load(offset);
			case F64: F64Load(offset);
			default: I32Load(offset);
		};

	static function store(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Store(offset);
			case F64: F64Store(offset);
			default: I32Store(offset);
		};
}

/** Native Wasm GC representation: engine references and declared struct/array fields. */
class WasmGcRepresentation implements WasmRepresentation {
	final plan:WasmGcTypePlan;
	final arrayReferenceLocals:Map<String, Int> = [];
	var allocateLocal:WasmValueType->Int;
	var exceptionTag:Null<Int>;
	var requiredArrayLengthLocal:Null<Int>;
	var arrayCapacityLocal:Null<Int>;
	var scratchAllocator:Int = -1;
	var scratchTop:Int = -1;

	public function new(plan:WasmGcTypePlan)
		this.plan = plan;

	public function configureCNativeScratch(scratchTop:Int, scratchAllocator:Int):Void {
		this.scratchTop = scratchTop;
		this.scratchAllocator = scratchAllocator;
	}

	public function valueType(type:IrType):WasmValueType
		return plan.valueType(type);

	public function zeroValue(type:IrType):Array<WasmInstruction>
		return switch valueType(type) {
			case I32: [I32Const(0)];
			case I64: [I64Const(0)];
			case F32: throw "The IR does not define an F32 zero value";
			case F64: [F64Const(0)];
			case Ref(ref): [RefNull(ref.heap)];
		};

	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>
		return switch valueType(type) {
			case Ref(ref): [RefNull(ref.heap), LocalSet(destination)];
			default: throw 'Wasm GC null value requires a reference type, got $type';
		};

	public function constantString(value:String, destination:Int, strings:Map<String, Int>):Null<Array<WasmInstruction>> {
		if (value == "Reached compiler-generated unreachable block")
			return [Unreachable];
		var bytes = HaxeBytes.ofString(value),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			body:Array<WasmInstruction> = [
				I32Const(bytes.length),
				ArrayNewDefault(plan.byteArrayTypeIndex),
				LocalSet(storage)
			];
		for (index in 0...bytes.length)
			body = body.concat([
				LocalGet(storage),
				I32Const(index),
				I32Const(bytes.get(index)),
				ArraySet(plan.byteArrayTypeIndex)
			]);
		body = body.concat([
			LocalGet(storage),
			I32Const(0),
			I32Const(bytes.length),
			StructNew(plan.bytesTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	public function newObject(typeName:String, destination:Int):Array<WasmInstruction>
		return [StructNewDefault(plan.objectType(typeName)), LocalSet(destination)];

	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var objectName = requireObjectName(object.type),
			typeIndex = plan.objectType(objectName),
			fieldIndex = plan.objectFieldIndex(objectName, fieldName);
		return [LocalGet(objectLocal), StructGet(typeIndex, fieldIndex), LocalSet(destination)];
	}

	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var objectName = requireObjectName(object.type),
			typeIndex = plan.objectType(objectName),
			fieldIndex = plan.objectFieldIndex(objectName, fieldName);
		return [LocalGet(objectLocal), LocalGet(valueLocal), StructSet(typeIndex, fieldIndex)];
	}

	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>> {
		var boxed = switch value.type {
			case I32, Bool, I64, F64, TypeRef: plan.boxedPrimitiveType(value.type);
			default: null;
		};
		if (boxed == null)
			return switch value.type {
				case Obj(_), Enum(_), Array(_), Iterator(_), Function(_, _), Bytes, ManagedBytes, Dyn, Abstract(_), Virtual(_):
					[LocalGet(valueLocal), LocalSet(destination)];
				default:
					throw 'Wasm GC cannot convert $value.type to Dynamic yet';
			};
		return [LocalGet(valueLocal), StructNew(boxed), LocalSet(destination)];
	}

	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>> {
		var boxType = switch output.type {
			case I32, Bool, I64, F64, TypeRef if (value.type == Dyn): plan.boxedPrimitiveType(output.type);
			default: null;
		};
		if (boxType != null)
			return [
				LocalGet(valueLocal),
				RefCast({nullable: false, heap: Type(boxType)}),
				StructGet(boxType, 0),
				LocalSet(destination)
			];
		return switch output.type {
			case Obj(_), Enum(_), Array(_), Iterator(_), Function(_, _), Bytes, ManagedBytes:
				var target = switch plan.valueType(output.type) {
					case Ref(reference): reference;
					default: throw 'Expected a Wasm GC reference type for $output.type';
				};
				[LocalGet(valueLocal), RefCast(target), LocalSet(destination)];
			case Virtual(interfaceName):
				var implementors = plan.interfaceImplementors(interfaceName),
					instructions:Array<WasmInstruction> = [
						LocalGet(valueLocal),             RefIsNull, If(null),
						LocalGet(valueLocal), LocalSet(destination),     Else
					];
				if (implementors.length == 0)
					instructions.push(Unreachable);
				for (index in 0...implementors.length) {
					var objectType = implementors[index];
					instructions = instructions.concat([
						LocalGet(valueLocal),
						RefTest({nullable: false, heap: Type(objectType)}),
						If(null),
						LocalGet(valueLocal),
						LocalSet(destination),
						Else
					]);
					if (index == implementors.length - 1)
						instructions.push(Unreachable);
				}
				for (_ in implementors)
					instructions.push(End);
				instructions.push(End);
				instructions;
			case Dyn, Abstract(_):
				[LocalGet(valueLocal), LocalSet(destination)];
			case _ if (output.type == value.type):
				[LocalGet(valueLocal), LocalSet(destination)];
			default:
				throw 'Wasm GC cannot cast ${Std.string(value.type)} to ${Std.string(output.type)} yet';
		};
	}

	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>>
		return switch value.type {
			case Obj(_), Enum(_), Array(_), Iterator(_), Function(_, _), Bytes, ManagedBytes, Dyn, Abstract(_), Virtual(_):
				[LocalGet(valueLocal), LocalSet(destination)];
			default:
				throw 'Wasm GC cannot convert $value.type to a virtual interface yet';
		};

	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		return switch left.type {
			case Obj(_), Enum(_), Array(_), Iterator(_), Function(_, _), Bytes, ManagedBytes:
				[LocalGet(leftLocal), LocalGet(rightLocal), RefEq, LocalSet(output)];
			case I64:
				[LocalGet(leftLocal), LocalGet(rightLocal), I64Eq, LocalSet(output)];
			case F64:
				[LocalGet(leftLocal), LocalGet(rightLocal), F64Eq, LocalSet(output)];
			case I32, Bool, TypeRef:
				[LocalGet(leftLocal), LocalGet(rightLocal), I32Eq, LocalSet(output)];
			case Dyn, Abstract(_), Virtual(_):
				[
					 LocalGet(leftLocal), RefCast({nullable: true, heap: Eq}),
					LocalGet(rightLocal), RefCast({nullable: true, heap: Eq}),
					               RefEq,                    LocalSet(output)
				];
			case Void:
				throw "Wasm GC cannot compare void values";
		};
	}

	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):Null<Array<WasmInstruction>> {
		var instructions:Array<WasmInstruction> = [I32Const(0), LocalSet(output)];
		var boxedTypes:Array<IrType> = [I32, Bool, I64, F64, TypeRef];
		for (type in boxedTypes) {
			var box = plan.boxedPrimitiveType(type), comparison = switch type {
				case I64: I64Eq;
				case F64: F64Eq;
				default: I32Eq;
			};
			instructions = instructions.concat([
				LocalGet(leftLocal),
				RefTest({nullable: false, heap: Type(box)}),
				LocalGet(rightLocal),
				RefTest({nullable: false, heap: Type(box)}),
				I32And,
				If(null),
				LocalGet(leftLocal),
				RefCast({nullable: false, heap: Type(box)}),
				StructGet(box, 0),
				LocalGet(rightLocal),
				RefCast({nullable: false, heap: Type(box)}),
				StructGet(box, 0),
				comparison,
				LocalSet(output),
				Else
			]);
		}
		var leftBytes = allocateLocal(Ref({nullable: false, heap: Type(plan.bytesTypeIndex)})),
			rightBytes = allocateLocal(Ref({nullable: false, heap: Type(plan.bytesTypeIndex)}));
		instructions = instructions.concat([
			LocalGet(leftLocal),
			RefTest({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			LocalGet(rightLocal),
			RefTest({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			I32And,
			If(null),
			LocalGet(leftLocal),
			RefCast({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			LocalSet(leftBytes),
			LocalGet(rightLocal),
			RefCast({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			LocalSet(rightBytes)
		]);
		instructions = instructions.concat(bytesEqual(output, leftBytes, rightBytes));
		instructions = instructions.concat([
			Else,
			LocalGet(leftLocal),
			RefCast({nullable: true, heap: Eq}),
			LocalGet(rightLocal),
			RefCast({nullable: true, heap: Eq}),
			RefEq,
			LocalSet(output),
			End
		]);
		for (_ in boxedTypes)
			instructions.push(End);
		return instructions;
	}

	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{typeName:String, functionIndex:Int}>,
			receiverLocal:Int, destination:Int, argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		if (targets.length == 0)
			throw 'Wasm GC interface method on ${Std.string(receiver.type)} has no implementations';
		var instructions:Array<WasmInstruction> = [];
		for (index in 0...targets.length) {
			var target = targets[index],
				objectType = plan.objectType(target.typeName);
			instructions = instructions.concat([
				LocalGet(receiverLocal),
				RefTest({nullable: false, heap: Type(objectType)}),
				If(null),
				LocalGet(receiverLocal),
				RefCast({nullable: false, heap: Type(objectType)})
			]);
			for (local in argumentLocals)
				instructions.push(LocalGet(local));
			instructions.push(Call(target.functionIndex));
			if (output.type != Void)
				instructions.push(LocalSet(destination));
			instructions = instructions.concat(index < targets.length - 1 ? [Else] : [Else, Unreachable]);
		}
		for (_ in targets)
			instructions.push(End);
		return instructions;
	}

	public function beginFunction(allocateLocal:WasmValueType->Int, exceptionTag:Null<Int>):Void {
		this.allocateLocal = allocateLocal;
		this.exceptionTag = exceptionTag;
		arrayReferenceLocals.clear();
		requiredArrayLengthLocal = null;
		arrayCapacityLocal = null;
	}

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		if (name == "__dynamic_equal") {
			if (output.type != Bool || arguments.length != 2 || argumentLocals.length != 2 || arguments[0].type != Dyn || arguments[1].type != Dyn)
				throw "Invalid Wasm GC dynamic equality signature";
			return dynamicEqual(outputLocal, argumentLocals[0], argumentLocals[1]);
		}
		if (name == "__bytes_alloc") {
			if (output.type != ManagedBytes || arguments.length != 1 || arguments[0].type != I32 || argumentLocals.length != 1)
				throw "Invalid Wasm GC Bytes.alloc signature";
			return bytesAlloc(argumentLocals[0], outputLocal);
		}
		if (name == "__bytes_of_string") {
			if (output.type != ManagedBytes || arguments.length != 1 || arguments[0].type != Bytes || argumentLocals.length != 1)
				throw "Invalid Wasm GC Bytes.ofString signature";
			return bytesFromString(argumentLocals[0], outputLocal);
		}
		if (name == "__bytes_length") {
			if (output.type != I32 || arguments.length != 1 || arguments[0].type != ManagedBytes || argumentLocals.length != 1)
				throw "Invalid Wasm GC Bytes.length signature";
			return [
				LocalGet(argumentLocals[0]),
				StructGet(plan.managedBytesTypeIndex, 2),
				LocalSet(outputLocal)
			];
		}
		if (name == "__bytes_get") {
			if (output.type != I32 || arguments.length != 2 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || argumentLocals.length != 2)
				throw "Invalid Wasm GC Bytes.get signature";
			return managedByteGet(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__bytes_set") {
			if (output.type != Void || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || arguments[2].type != I32
				|| argumentLocals.length != 3)
				throw "Invalid Wasm GC Bytes.set signature";
			return managedByteSet(argumentLocals[0], argumentLocals[1], argumentLocals[2]);
		}
		if (name == "__bytes_get_i32") {
			if (output.type != I32 || arguments.length != 2 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || argumentLocals.length != 2)
				throw "Invalid Wasm GC Bytes.getInt32 signature";
			return managedByteGetI32(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__bytes_set_i32") {
			if (output.type != Void || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || arguments[2].type != I32
				|| argumentLocals.length != 3)
				throw "Invalid Wasm GC Bytes.setInt32 signature";
			return managedByteSetI32(argumentLocals[0], argumentLocals[1], argumentLocals[2]);
		}
		if (name == "__bytes_view" || name == "__bytes_sub") {
			if (output.type != ManagedBytes || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32
				|| arguments[2].type != I32 || argumentLocals.length != 3)
				throw 'Invalid Wasm GC $name signature';
			return name == "__bytes_view" ? managedBytesView(argumentLocals[0], argumentLocals[1], argumentLocals[2],
				outputLocal) : managedBytesSub(argumentLocals[0], argumentLocals[1], argumentLocals[2], outputLocal);
		}
		if (name == "__bytes_compare") {
			if (output.type != I32 || arguments.length != 2 || arguments[0].type != ManagedBytes || arguments[1].type != ManagedBytes
				|| argumentLocals.length != 2)
				throw "Invalid Wasm GC Bytes.compare signature";
			return managedBytesCompare(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__bytes_to_string") {
			if (output.type != Bytes || arguments.length != 1 || arguments[0].type != ManagedBytes || argumentLocals.length != 1)
				throw "Invalid Wasm GC Bytes.toString signature";
			return managedBytesToString(argumentLocals[0], outputLocal);
		}
		if (name == "__bytes_get_string") {
			if (output.type != Bytes || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || arguments[2].type != I32
				|| argumentLocals.length != 3)
				throw "Invalid Wasm GC Bytes.getString signature";
			return managedBytesGetString(argumentLocals[0], argumentLocals[1], argumentLocals[2], outputLocal);
		}
		if (name == "__string_length") {
			if (output.type != I32 || arguments.length != 1 || argumentLocals.length != 1 || arguments[0].type != Bytes)
				throw "Invalid Wasm GC string length signature";
			return [
				LocalGet(argumentLocals[0]),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(outputLocal)
			];
		}
		if (name == "__string_char_code_at")
			return stringCharCodeAt(output, arguments, outputLocal, argumentLocals);
		if (name == "__string_concat")
			return stringConcat(output, arguments, outputLocal, argumentLocals);
		if (name == "__string_equal") {
			if (output.type != Bool || arguments.length != 2 || argumentLocals.length != 2 || arguments[0].type != Bytes || arguments[1].type != Bytes)
				throw "Invalid Wasm GC string equality signature";
			return bytesEqual(outputLocal, argumentLocals[0], argumentLocals[1]);
		}
		if (StringTools.startsWith(name, "__array_alloc_")) {
			if (arguments.length != 1 || argumentLocals.length != 1)
				throw 'Invalid Wasm GC array allocator signature for "$name"';
			var element = requireArrayElement(output.type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_alloc_" + suffix)
				throw 'Wasm GC array allocator "$name" does not match its $element result type';
			var length = argumentLocals[0];
			return [
				LocalGet(length),
				LocalGet(length),
				I32Const(8),
				I32Add,
				ArrayNewDefault(plan.arrayStorageType(element)),
				StructNew(plan.arrayType(element)),
				LocalSet(outputLocal)
			];
		}
		if (StringTools.startsWith(name, "__array_push_")) {
			if (arguments.length != 2 || argumentLocals.length != 2 || output.type != I32)
				throw 'Invalid Wasm GC array push signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_push_" + suffix)
				throw 'Wasm GC array push "$name" does not match its $element array';
			var array = arguments[0],
				value = arguments[1],
				lengthLocal = allocateLocal(I32),
				arrayType = plan.arrayType(element),
				arrayLocal = argumentLocals[0];
			var body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(arrayType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(lengthLocal)
			];
			body = body.concat(requireInstructions(arraySet(array, new IrValue(-1, "push-index", I32), value, arrayLocal, lengthLocal, argumentLocals[1])));
			body = body.concat([LocalGet(lengthLocal), I32Const(1), I32Add, LocalSet(outputLocal)]);
			return body;
		}
		return null;
	}

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>,
			importIndex:Int):Null<Array<WasmInstruction>> {
		var hasByteInputs = false;
		for (mode in native.argumentModes)
			switch mode {
				case BytesInput(_) | BytesInputOutput(_):
					hasByteInputs = true;
				case Value:
				case BytesOutput(_) | Output | InputOutput:
					throw 'Wasm GC C native "${native.name}" supports input byte slices only so far';
			}
		if (hasByteInputs && (scratchAllocator < 0 || scratchTop < 0))
			throw 'Wasm GC C native "${native.name}" requires a configured linear scratch bridge';
		var body:Array<WasmInstruction> = [],
			savedTop = hasByteInputs ? allocateLocal(I32) : -1,
			bytePointers:Array<Null<Int>> = [];
		if (hasByteInputs)
			body = body.concat([GlobalGet(scratchTop), LocalSet(savedTop)]);
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInput(_) | BytesInputOutput(_):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte input $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32),
						position = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						Call(scratchAllocator),
						LocalSet(pointer),
						I32Const(0),
						LocalSet(position),
						Block(null),
						Loop(null),
						LocalGet(position),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32LtS,
						I32Eqz,
						BrIf(1),
						LocalGet(pointer),
						LocalGet(position),
						I32Add,
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 0),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 1),
						LocalGet(position),
						I32Add,
						ArrayGetUnsigned(plan.byteArrayTypeIndex),
						I32Store8(0),
						LocalGet(position),
						I32Const(1),
						I32Add,
						LocalSet(position),
						Br(0),
						End,
						End
					]);
				case Value:
					bytePointers[index] = null;
				case _:
					throw 'Wasm GC C native "${native.name}" has an unsupported argument direction';
			}
		for (index in 0...arguments.length) {
			var pointer = bytePointers[index];
			body.push(LocalGet(pointer == null ? argumentLocals[index] : pointer));
		}
		var resultLocal = native.result == Void ? -1 : allocateLocal(valueType(native.result));
		body.push(Call(importIndex));
		if (resultLocal >= 0)
			body.push(LocalSet(resultLocal));
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInputOutput(_):
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" mutable byte input $index has no scratch pointer';
					var bytesLocal = argumentLocals[index],
						position = allocateLocal(I32);
					body = body.concat([
						I32Const(0),
						LocalSet(position),
						Block(null),
						Loop(null),
						LocalGet(position),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32LtS,
						I32Eqz,
						BrIf(1),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 0),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 1),
						LocalGet(position),
						I32Add,
						LocalGet(pointer),
						LocalGet(position),
						I32Add,
						I32Load8U(0),
						ArraySet(plan.byteArrayTypeIndex),
						LocalGet(position),
						I32Const(1),
						I32Add,
						LocalSet(position),
						Br(0),
						End,
						End
					]);
				case _:
			}
		if (hasByteInputs)
			body = body.concat([LocalGet(savedTop), GlobalSet(scratchTop)]);
		if (resultLocal >= 0)
			body = body.concat([LocalGet(resultLocal), LocalSet(outputLocal)]);
		return body;
	}

	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireArrayElement(array.type),
			wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element);
		var body:Array<WasmInstruction> = checkedIndex(indexLocal, arrayLocal, wrapperType);
		body = body.concat([
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(indexLocal),
			ArrayGet(storageType),
			LocalSet(destination)
		]);
		return body;
	}

	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireArrayElement(array.type),
			wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			newStorageLocal = arrayReferenceLocal(element),
			requiredLength = requiredArrayLength(),
			capacity = arrayCapacity();
		var body:Array<WasmInstruction> = [LocalGet(indexLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body.push(End);
		body = body.concat([
			LocalGet(indexLocal),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			I32LtS,
			If(null),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(indexLocal),
			LocalGet(valueLocal),
			ArraySet(storageType),
			Else,
			LocalGet(indexLocal),
			I32Const(1),
			I32Add,
			LocalSet(requiredLength),
			LocalGet(requiredLength),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			ArrayLen,
			I32LeS,
			If(null),
			LocalGet(arrayLocal),
			LocalGet(requiredLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(indexLocal),
			LocalGet(valueLocal),
			ArraySet(storageType),
			Else,
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			ArrayLen,
			I32Const(2),
			I32Mul,
			LocalSet(capacity),
			LocalGet(capacity),
			LocalGet(requiredLength),
			I32LtS,
			If(null),
			LocalGet(requiredLength),
			LocalSet(capacity),
			End,
			LocalGet(capacity),
			ArrayNewDefault(storageType),
			LocalSet(newStorageLocal),
			LocalGet(newStorageLocal),
			I32Const(0),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			I32Const(0),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			ArrayCopy(storageType, storageType),
			LocalGet(arrayLocal),
			LocalGet(newStorageLocal),
			StructSet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(arrayLocal),
			LocalGet(requiredLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(indexLocal),
			LocalGet(valueLocal),
			ArraySet(storageType),
			End,
			End
		]);
		return body;
	}

	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireArrayElement(array.type),
			wrapperType = plan.arrayType(element);
		return [
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			LocalSet(destination)
		];
	}

	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireArrayElement(array.type),
			iteratorType = plan.iteratorType(element);
		return [
			LocalGet(arrayLocal),
			I32Const(0),
			StructNew(iteratorType),
			LocalSet(destination)
		];
	}

	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireIteratorElement(iterator.type),
			iteratorType = plan.iteratorType(element),
			arrayType = plan.arrayType(element);
		return [
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorPositionFieldIndex()),
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorArrayFieldIndex()),
			StructGet(arrayType, WasmGcTypePlan.arrayLengthFieldIndex()),
			I32LtS,
			LocalSet(destination)
		];
	}

	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):Null<Array<WasmInstruction>> {
		var element = requireIteratorElement(iterator.type),
			iteratorType = plan.iteratorType(element),
			arrayType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element);
		var body:Array<WasmInstruction> = [
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorPositionFieldIndex()),
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorArrayFieldIndex()),
			StructGet(arrayType, WasmGcTypePlan.arrayLengthFieldIndex()),
			I32LtS,
			If(null),
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorArrayFieldIndex()),
			StructGet(arrayType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorPositionFieldIndex()),
			ArrayGet(storageType),
			LocalSet(destination),
			LocalGet(iteratorLocal),
			LocalGet(iteratorLocal),
			StructGet(iteratorType, WasmGcTypePlan.iteratorPositionFieldIndex()),
			I32Const(1),
			I32Add,
			StructSet(iteratorType, WasmGcTypePlan.iteratorPositionFieldIndex()),
			Else
		];
		body = body.concat(trapInstructions());
		body.push(End);
		return body;
	}

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		var body:Array<WasmInstruction> = [I32Const(constructor)];
		for (local in argumentLocals)
			body.push(LocalGet(local));
		body.push(StructNew(plan.enumConstructorType(typeName, constructor)));
		body.push(LocalSet(destination));
		return body;
	}

	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>> {
		var typeName = requireEnumName(value.type);
		return [
			LocalGet(valueLocal),
			StructGet(plan.enumType(typeName), 0),
			LocalSet(destination)
		];
	}

	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):Null<Array<WasmInstruction>> {
		var typeName = requireEnumName(value.type),
			constructorType = plan.enumConstructorType(typeName, constructor),
			fieldIndex = plan.enumFieldIndex(typeName, constructor, field);
		return [
			LocalGet(valueLocal),
			RefCast({nullable: false, heap: Type(constructorType)}),
			StructGet(constructorType, fieldIndex),
			LocalSet(destination)
		];
	}

	public function staticClosure(name:String, tableSlots:Map<String, Int>, destination:Int):Null<Array<WasmInstruction>> {
		var tableSlot = tableSlots.get(name);
		if (tableSlot == null)
			throw 'Wasm GC closure target "$name" has no stable table slot';
		return [
			I32Const(tableSlot * 2 + 1),
			RefNull(Any),
			StructNew(plan.closureTypeIndex),
			LocalSet(destination)
		];
	}

	public function instanceClosure(name:String, tableSlots:Map<String, Int>, receiverLocal:Int, destination:Int):Null<Array<WasmInstruction>> {
		var tableSlot = tableSlots.get(WasmBackend.gcClosureThunkName(name));
		if (tableSlot == null)
			throw 'Wasm GC instance closure target "$name" has no stable table slot';
		return [
			I32Const(tableSlot * 2),
			LocalGet(receiverLocal),
			StructNew(plan.closureTypeIndex),
			LocalSet(destination)
		];
	}

	public function callClosure(staticType:Int, instanceType:Null<Int>, arguments:Array<IrValue>, closureLocal:Int, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		var body:Array<WasmInstruction> = [];
		if (instanceType == null) {
			for (local in argumentLocals)
				body.push(LocalGet(local));
			body = body.concat([
				LocalGet(closureLocal),
				StructGet(plan.closureTypeIndex, 0),
				CallIndirect(staticType)
			]);
			if (destination >= 0)
				body.push(LocalSet(destination));
			return body;
		}
		body = body.concat([
			LocalGet(closureLocal),
			StructGet(plan.closureTypeIndex, 0),
			I32Const(1),
			I32And,
			If(null)
		]);
		for (local in argumentLocals)
			body.push(LocalGet(local));
		body = body.concat([
			LocalGet(closureLocal),
			StructGet(plan.closureTypeIndex, 0),
			I32Const(1),
			I32ShrU,
			CallIndirect(staticType)
		]);
		if (destination >= 0)
			body.push(LocalSet(destination));
		body.push(Else);
		body.push(LocalGet(closureLocal));
		body.push(StructGet(plan.closureTypeIndex, 1));
		for (local in argumentLocals)
			body.push(LocalGet(local));
		body = body.concat([
			LocalGet(closureLocal),
			StructGet(plan.closureTypeIndex, 0),
			I32Const(1),
			I32ShrU,
			CallIndirect(instanceType)
		]);
		if (destination >= 0)
			body.push(LocalSet(destination));
		body.push(End);
		return body;
	}

	function arrayReferenceLocal(element:IrType):Int {
		var key = WasmGcTypePlan.typeKey(element),
			local = arrayReferenceLocals.get(key);
		if (local == null) {
			local = allocateLocal(Ref({nullable: false, heap: Type(plan.arrayStorageType(element))}));
			arrayReferenceLocals.set(key, local);
		}
		return local;
	}

	function requiredArrayLength():Int {
		if (requiredArrayLengthLocal == null)
			requiredArrayLengthLocal = allocateLocal(I32);
		return requiredArrayLengthLocal;
	}

	function arrayCapacity():Int {
		if (arrayCapacityLocal == null)
			arrayCapacityLocal = allocateLocal(I32);
		return arrayCapacityLocal;
	}

	function checkedIndex(indexLocal:Int, arrayLocal:Int, wrapperType:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(indexLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body.push(End);
		body = body.concat([
			LocalGet(indexLocal),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			I32LtS,
			I32Eqz,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body.push(End);
		return body;
	}

	function trapInstructions():Array<WasmInstruction>
		return exceptionTag == null ? [Unreachable] : [RefNull(Any), Throw(exceptionTag)];

	function bytesAlloc(lengthLocal:Int, destination:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(lengthLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(lengthLocal),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			I32Const(0),
			LocalGet(lengthLocal),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function bytesFromString(stringLocal:Int, destination:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)}));
		return [
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 2),
			LocalSet(length),
			LocalGet(length),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(storage),
			LocalGet(storage),
			I32Const(0),
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 0),
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(length),
			ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
			LocalGet(storage),
			I32Const(0),
			LocalGet(length),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(destination)
		];
	}

	function managedByteGet(bytesLocal:Int, indexLocal:Int, destination:Int):Array<WasmInstruction> {
		var body = checkedByteIndex(plan.managedBytesTypeIndex, bytesLocal, indexLocal, 1);
		body = body.concat([
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(indexLocal),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function managedByteSet(bytesLocal:Int, indexLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var body = checkedByteIndex(plan.managedBytesTypeIndex, bytesLocal, indexLocal, 1);
		body = body.concat([
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(indexLocal),
			I32Add,
			LocalGet(valueLocal),
			ArraySet(plan.byteArrayTypeIndex)
		]);
		return body;
	}

	function managedByteGetI32(bytesLocal:Int, indexLocal:Int, destination:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = checkedByteIndex(plan.managedBytesTypeIndex, bytesLocal, indexLocal, 4);
		for (byteIndex in 0...4) {
			body = body.concat([
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(indexLocal),
				I32Add,
				I32Const(byteIndex),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex)
			]);
			if (byteIndex > 0)
				body = body.concat([I32Const(byteIndex * 8), I32Shl]);
			if (byteIndex > 0)
				body.push(I32Or);
		}
		body.push(LocalSet(destination));
		return body;
	}

	function managedByteSetI32(bytesLocal:Int, indexLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = checkedByteIndex(plan.managedBytesTypeIndex, bytesLocal, indexLocal, 4);
		for (byteIndex in 0...4) {
			body = body.concat([
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(bytesLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(indexLocal),
				I32Add,
				I32Const(byteIndex),
				I32Add,
				LocalGet(valueLocal)
			]);
			if (byteIndex > 0)
				body = body.concat([I32Const(byteIndex * 8), I32ShrU]);
			body.push(ArraySet(plan.byteArrayTypeIndex));
		}
		return body;
	}

	function managedBytesView(bytesLocal:Int, offsetLocal:Int, lengthLocal:Int, destination:Int):Array<WasmInstruction> {
		var body = checkedByteRange(plan.managedBytesTypeIndex, bytesLocal, offsetLocal, lengthLocal);
		body = body.concat([
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(offsetLocal),
			I32Add,
			LocalGet(lengthLocal),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function managedBytesSub(bytesLocal:Int, offsetLocal:Int, lengthLocal:Int, destination:Int):Array<WasmInstruction> {
		var body = checkedByteRange(plan.managedBytesTypeIndex, bytesLocal, offsetLocal, lengthLocal),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)}));
		body = body.concat([
			LocalGet(lengthLocal),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(storage),
			LocalGet(storage),
			I32Const(0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(offsetLocal),
			I32Add,
			LocalGet(lengthLocal),
			ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
			LocalGet(storage),
			I32Const(0),
			LocalGet(lengthLocal),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function managedBytesCompare(leftLocal:Int, rightLocal:Int, destination:Int):Array<WasmInstruction> {
		var leftLength = allocateLocal(I32),
			rightLength = allocateLocal(I32),
			index = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(leftLocal),
				StructGet(plan.managedBytesTypeIndex, 2),
				LocalSet(leftLength),
				LocalGet(rightLocal),
				StructGet(plan.managedBytesTypeIndex, 2),
				LocalSet(rightLength),
				I32Const(0),
				LocalSet(destination),
				I32Const(0),
				LocalSet(index),
				Block(null),
				Loop(null),
				LocalGet(index),
				LocalGet(leftLength),
				I32LtS,
				I32Eqz,
				LocalGet(index),
				LocalGet(rightLength),
				I32LtS,
				I32Eqz,
				I32Or,
				BrIf(1),
				LocalGet(leftLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(leftLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				LocalGet(rightLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(rightLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				I32LtS,
				If(null),
				I32Const(-1),
				LocalSet(destination),
				Br(2),
				End,
				LocalGet(rightLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(rightLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				LocalGet(leftLocal),
				StructGet(plan.managedBytesTypeIndex, 0),
				LocalGet(leftLocal),
				StructGet(plan.managedBytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				I32LtS,
				If(null),
				I32Const(1),
				LocalSet(destination),
				Br(2),
				End,
				LocalGet(index),
				I32Const(1),
				I32Add,
				LocalSet(index),
				Br(0),
				End,
				End
			];
		body = body.concat([
			LocalGet(destination),
			I32Eqz,
			If(null),
			LocalGet(leftLength),
			LocalGet(rightLength),
			I32LtS,
			If(null),
			I32Const(-1),
			LocalSet(destination),
			Else,
			LocalGet(rightLength),
			LocalGet(leftLength),
			I32LtS,
			If(null),
			I32Const(1),
			LocalSet(destination),
			End,
			End,
			End
		]);
		return body;
	}

	function managedBytesToString(bytesLocal:Int, destination:Int):Array<WasmInstruction>
		return [
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 2),
			StructNew(plan.bytesTypeIndex),
			LocalSet(destination)
		];

	function managedBytesGetString(bytesLocal:Int, offsetLocal:Int, lengthLocal:Int, destination:Int):Array<WasmInstruction> {
		var body = checkedByteRange(plan.managedBytesTypeIndex, bytesLocal, offsetLocal, lengthLocal);
		body = body.concat([
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 0),
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 1),
			LocalGet(offsetLocal),
			I32Add,
			LocalGet(lengthLocal),
			StructNew(plan.bytesTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function checkedByteRange(wrapperType:Int, bytesLocal:Int, offsetLocal:Int, lengthLocal:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(offsetLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([End, LocalGet(lengthLocal), I32Const(0), I32LtS, If(null)]);
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			LocalGet(lengthLocal),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			LocalGet(lengthLocal),
			I32Sub,
			LocalGet(offsetLocal),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body.push(End);
		return body;
	}

	function checkedByteIndex(wrapperType:Int, bytesLocal:Int, indexLocal:Int, width:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(indexLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			I32Const(width),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(bytesLocal),
			StructGet(wrapperType, 2),
			I32Const(width),
			I32Sub,
			LocalGet(indexLocal),
			I32LtS,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body.push(End);
		return body;
	}

	function stringCharCodeAt(output:IrValue, arguments:Array<IrValue>, destination:Int, argumentLocals:Array<Int>):Array<WasmInstruction> {
		if (output.type != I32 || arguments.length != 2 || argumentLocals.length != 2 || arguments[0].type != Bytes || arguments[1].type != I32)
			throw "Invalid Wasm GC string charCodeAt signature";
		var stringLocal = argumentLocals[0],
			indexLocal = argumentLocals[1],
			body:Array<WasmInstruction> = [LocalGet(indexLocal), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(indexLocal),
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 2),
			I32LtS,
			I32Eqz,
			If(null)
		]);
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 0),
			LocalGet(stringLocal),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(indexLocal),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			LocalSet(destination)
		]);
		return body;
	}

	function stringConcat(output:IrValue, arguments:Array<IrValue>, destination:Int, argumentLocals:Array<Int>):Array<WasmInstruction> {
		if (output.type != Bytes || arguments.length != 2 || argumentLocals.length != 2 || arguments[0].type != Bytes || arguments[1].type != Bytes)
			throw "Invalid Wasm GC string concatenation signature";
		var leftLocal = argumentLocals[0],
			rightLocal = argumentLocals[1],
			leftLength = allocateLocal(I32),
			rightLength = allocateLocal(I32),
			totalLength = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(plan.byteArrayTypeIndex)
			})),
			body:Array<WasmInstruction> = [
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(leftLength),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(rightLength),
				LocalGet(leftLength),
				LocalGet(rightLength),
				I32Add,
				LocalTee(totalLength),
				ArrayNewDefault(plan.byteArrayTypeIndex),
				LocalSet(storage),
				LocalGet(storage),
				I32Const(0),
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(leftLength),
				ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
				LocalGet(storage),
				LocalGet(leftLength),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(rightLength),
				ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
				LocalGet(storage),
				I32Const(0),
				LocalGet(totalLength),
				StructNew(plan.bytesTypeIndex),
				LocalSet(destination)
			];
		return body;
	}

	function bytesEqual(output:Int, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		var leftLength = allocateLocal(I32),
			rightLength = allocateLocal(I32),
			index = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(leftLength),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(rightLength),
				I32Const(0),
				LocalSet(output),
				LocalGet(leftLength),
				LocalGet(rightLength),
				I32Eq,
				If(null),
				I32Const(1),
				LocalSet(output),
				I32Const(0),
				LocalSet(index),
				Block(null),
				Loop(null),
				LocalGet(index),
				LocalGet(leftLength),
				I32LtS,
				I32Eqz,
				BrIf(1),
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				I32Eq,
				I32Eqz,
				If(null),
				I32Const(0),
				LocalSet(output),
				Br(2),
				End,
				LocalGet(index),
				I32Const(1),
				I32Add,
				LocalSet(index),
				Br(0),
				End,
				End,
				End
			];
		return body;
	}

	static function requireInstructions(instructions:Null<Array<WasmInstruction>>):Array<WasmInstruction>
		return if (instructions == null) throw "Wasm GC array operation was not lowered" else instructions;

	static function requireArrayElement(type:IrType):IrType
		return switch type {
			case Array(element): element;
			default: throw 'Wasm GC array operation requires an array, got ${Std.string(type)}';
		};

	static function requireIteratorElement(type:IrType):IrType
		return switch type {
			case Iterator(element): element;
			default: throw 'Wasm GC iterator operation requires an iterator, got ${Std.string(type)}';
		};

	static function requireEnumName(type:IrType):String
		return switch type {
			case Enum(name): name;
			default: throw 'Wasm GC enum operation requires an enum, got ${Std.string(type)}';
		};

	static function arrayNativeSuffix(type:IrType):String
		return switch type {
			case I32: "i32";
			case Bool: "bool";
			case F64: "f64";
			case Bytes, ManagedBytes: "bytes";
			default: "ref";
		};

	static function requireObjectName(type:IrType):String
		return switch type {
			case Obj(name): name;
			default: throw 'Wasm GC field access requires an object reference, got ${Std.string(type)}';
		};
}
