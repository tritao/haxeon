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
	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}>, receiverLocal:Int, destination:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
	public function beginFunction(allocateLocal:WasmValueType->Int, exceptionTag:Null<Int>):Void;
	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
		pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):Null<Array<WasmInstruction>>;
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

	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}>, receiverLocal:Int, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	public function beginFunction(allocateLocal:WasmValueType->Int, exceptionTag:Null<Int>):Void {}

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
		return null;

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):Null<Array<WasmInstruction>>
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
		return stringLiteral(value, destination);
	}

	function stringLiteral(value:String, destination:Int):Array<WasmInstruction> {
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

	function dynamicInt(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var instructions:Array<WasmInstruction> = [
			LocalGet(valueLocal),
			RefIsNull,
			If(null),
			I32Const(0),
			LocalSet(outputLocal),
			Else
		];
		var primitiveTypes:Array<IrType> = [IrType.I32, IrType.Bool, IrType.F64, IrType.I64];
		for (type in primitiveTypes) {
			var box = plan.boxedPrimitiveType(type),
				unbox:Array<WasmInstruction> = switch type {
					case I32, Bool: [StructGet(box, 0)];
					case F64: [StructGet(box, 0), I32TruncF64S];
					case I64: [StructGet(box, 0), I32WrapI64];
					default: throw 'Unsupported Wasm GC dynamic Int conversion from $type';
				};
			instructions = instructions.concat([
				LocalGet(valueLocal),
				RefTest({nullable: false, heap: Type(box)}),
				If(null),
				LocalGet(valueLocal),
				RefCast({nullable: false, heap: Type(box)})
			]);
			instructions = instructions.concat(unbox);
			instructions = instructions.concat([LocalSet(outputLocal), Else]);
		}
		instructions.push(Unreachable);
		for (_ in primitiveTypes)
			instructions.push(End);
		instructions.push(End);
		return instructions;
	}

	function dynamicTypeTest(valueLocal:Int, typeLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [I32Const(0), LocalSet(outputLocal)];
		appendTypeTest(body, valueLocal, typeLocal, outputLocal, I32, plan.boxedPrimitiveType(I32));
		appendTypeTest(body, valueLocal, typeLocal, outputLocal, Bool, plan.boxedPrimitiveType(Bool));
		appendTypeTest(body, valueLocal, typeLocal, outputLocal, F64, plan.boxedPrimitiveType(F64));
		appendTypeTest(body, valueLocal, typeLocal, outputLocal, I64, plan.boxedPrimitiveType(I64));
		appendTypeTest(body, valueLocal, typeLocal, outputLocal, Bytes, plan.bytesTypeIndex);
		for (object in plan.program.objects)
			appendTypeTest(body, valueLocal, typeLocal, outputLocal, Obj(object.name), plan.objectType(object.name));
		for (enumDecl in plan.program.enums)
			appendTypeTest(body, valueLocal, typeLocal, outputLocal, Enum(enumDecl.name), plan.enumType(enumDecl.name));
		appendArrayTypeTest(body, valueLocal, typeLocal, outputLocal);
		for (interfaceDecl in plan.program.interfaces)
			appendInterfaceTypeTest(body, valueLocal, typeLocal, outputLocal, interfaceDecl.name);
		return body;
	}

	function dynamicString(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [
			RefNull(Type(plan.bytesTypeIndex)),
			LocalSet(outputLocal),
			LocalGet(valueLocal),
			RefIsNull,
			If(null)
		];
		body = body.concat(stringLiteral("null", outputLocal));
		body = body.concat([
			Else,
			LocalGet(valueLocal),
			RefTest({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			If(null)
		]);
		body = body.concat([
			LocalGet(valueLocal),
			RefCast({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			LocalSet(outputLocal),
			Else
		]);
		body = body.concat(stringLiteral("Object", outputLocal));
		body = body.concat(dynamicIntegerString(valueLocal, outputLocal));
		body = body.concat(dynamicFloatString(valueLocal, outputLocal));
		body = body.concat(dynamicBooleanString(valueLocal, outputLocal));
		for (enumDecl in plan.program.enums)
			for (index in 0...enumDecl.cases.length) {
				var constructor = enumDecl.cases[index];
				if (constructor.params.length == 0) {
					body = body.concat([
						LocalGet(valueLocal),
						RefTest({nullable: false, heap: Type(plan.enumConstructorType(enumDecl.name, index))}),
						If(null)
					]);
					body = body.concat(stringLiteral(constructor.name, outputLocal));
					body.push(End);
				}
			}
		body = body.concat([End, End]);
		return body;
	}

	function dynamicIntegerString(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var boxType = plan.boxedPrimitiveType(I32),
			body:Array<WasmInstruction> = [LocalGet(valueLocal), RefTest({nullable: false, heap: Type(boxType)}), If(null)];
		body = body.concat(integerString(valueLocal, boxType, outputLocal));
		body.push(End);
		return body;
	}

	function integerString(valueLocal:Int, boxType:Int, outputLocal:Int):Array<WasmInstruction> {
		var value = allocateLocal(I32);
		return [
			LocalGet(valueLocal),
			RefCast({nullable: false, heap: Type(boxType)}),
			StructGet(boxType, 0),
			LocalSet(value)
		].concat(integerValueString(value, outputLocal));
	}

	function integerValueString(value:Int, outputLocal:Int):Array<WasmInstruction> {
		var negative = allocateLocal(I32),
			position = allocateLocal(I32),
			digit = allocateLocal(I32),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			body:Array<WasmInstruction> = [
				LocalGet(value),
				I32Const(0),
				I32LtS,
				LocalSet(negative),
				I32Const(11),
				ArrayNewDefault(plan.byteArrayTypeIndex),
				LocalSet(storage),
				I32Const(10),
				LocalSet(position),
				LocalGet(value),
				I32Eqz,
				If(null),
				LocalGet(storage),
				LocalGet(position),
				I32Const(48),
				ArraySet(plan.byteArrayTypeIndex),
				LocalGet(position),
				I32Const(1),
				I32Sub,
				LocalSet(position),
				Else,
				Block(null),
				Loop(null),
				LocalGet(value),
				I32Eqz,
				BrIf(1),
				LocalGet(value),
				I32Const(10),
				I32RemS,
				LocalSet(digit),
				LocalGet(digit),
				I32Const(0),
				I32LtS,
				If(I32),
				I32Const(0),
				LocalGet(digit),
				I32Sub,
				Else,
				LocalGet(digit),
				End,
				I32Const(48),
				I32Add,
				LocalSet(digit),
				LocalGet(storage),
				LocalGet(position),
				LocalGet(digit),
				ArraySet(plan.byteArrayTypeIndex),
				LocalGet(position),
				I32Const(1),
				I32Sub,
				LocalSet(position),
				LocalGet(value),
				I32Const(10),
				I32DivS,
				LocalSet(value),
				Br(0),
				End,
				End,
				End,
				LocalGet(negative),
				If(null),
				LocalGet(storage),
				LocalGet(position),
				I32Const(45),
				ArraySet(plan.byteArrayTypeIndex),
				LocalGet(position),
				I32Const(1),
				I32Sub,
				LocalSet(position),
				End,
				LocalGet(storage),
				LocalGet(position),
				I32Const(1),
				I32Add,
				I32Const(10),
				LocalGet(position),
				I32Sub,
				StructNew(plan.bytesTypeIndex),
				LocalSet(outputLocal)
			];
		return body;
	}

	function dynamicFloatString(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var boxType = plan.boxedPrimitiveType(F64),
			value = allocateLocal(F64),
			negative = allocateLocal(I32),
			absolute = allocateLocal(F64),
			whole = allocateLocal(I32),
			fraction = allocateLocal(I32),
			fractionDigits = allocateLocal(I32),
			wholeString = allocateLocal(valueType(Bytes)),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(plan.byteArrayTypeIndex)
			})),
			writeIndex = allocateLocal(I32),
			index = allocateLocal(I32),
			divisor = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(valueLocal),
				RefTest({
					nullable: false,
					heap: Type(boxType)
				}),
				If(null),
				LocalGet(valueLocal),
				RefCast({nullable: false, heap: Type(boxType)}),
				StructGet(boxType, 0),
				LocalSet(value),
				LocalGet(value),
				F64Const(0),
				F64Lt,
				LocalSet(negative),
				LocalGet(negative),
				If(F64),
				F64Const(0),
				LocalGet(value),
				F64Sub,
				Else,
				LocalGet(value),
				End,
				LocalSet(absolute),
				LocalGet(absolute),
				F64Const(2147483648.0),
				F64Lt,
				If(null),
				LocalGet(absolute),
				I32TruncF64S,
				LocalSet(whole)
			];
		body = body.concat(integerValueString(whole, wholeString));
		body = body.concat([
			LocalGet(absolute),
			LocalGet(whole),
			F64ConvertI32S,
			F64Sub,
			F64Const(1000000),
			F64Mul,
			I32TruncF64S,
			LocalSet(fraction),
			I32Const(6),
			LocalSet(fractionDigits),
			Block(null),
			Loop(null),
			LocalGet(fraction),
			I32Const(10),
			I32RemS,
			I32Eqz,
			LocalGet(fraction),
			I32Eqz,
			I32Eqz,
			I32And,
			I32Eqz,
			BrIf(1),
			LocalGet(fraction),
			I32Const(10),
			I32DivS,
			LocalSet(fraction),
			LocalGet(fractionDigits),
			I32Const(1),
			I32Sub,
			LocalSet(fractionDigits),
			Br(0),
			End,
			End,
			I32Const(24),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(storage),
			I32Const(0),
			LocalSet(writeIndex),
			LocalGet(negative),
			If(null),
			LocalGet(storage),
			LocalGet(writeIndex),
			I32Const(45),
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(writeIndex),
			I32Const(1),
			I32Add,
			LocalSet(writeIndex),
			End,
			LocalGet(storage),
			LocalGet(writeIndex),
			LocalGet(wholeString),
			StructGet(plan.bytesTypeIndex, 0),
			LocalGet(wholeString),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(wholeString),
			StructGet(plan.bytesTypeIndex, 2),
			ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
			LocalGet(writeIndex),
			LocalGet(wholeString),
			StructGet(plan.bytesTypeIndex, 2),
			I32Add,
			LocalSet(writeIndex),
			LocalGet(fraction),
			I32Eqz,
			If(null),
			Else,
			LocalGet(storage),
			LocalGet(writeIndex),
			I32Const(46),
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(writeIndex),
			I32Const(1),
			I32Add,
			LocalSet(writeIndex),
			I32Const(1),
			LocalSet(divisor),
			I32Const(1),
			LocalSet(index),
			Block(null),
			Loop(null),
			LocalGet(index),
			LocalGet(fractionDigits),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(divisor),
			I32Const(10),
			I32Mul,
			LocalSet(divisor),
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(0),
			End,
			End,
			I32Const(0),
			LocalSet(index),
			Block(null),
			Loop(null),
			LocalGet(index),
			LocalGet(fractionDigits),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(storage),
			LocalGet(writeIndex),
			LocalGet(fraction),
			LocalGet(divisor),
			I32DivS,
			I32Const(10),
			I32RemS,
			I32Const(48),
			I32Add,
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(fraction),
			LocalGet(divisor),
			I32RemS,
			LocalSet(fraction),
			LocalGet(divisor),
			I32Const(10),
			I32DivS,
			LocalSet(divisor),
			LocalGet(writeIndex),
			I32Const(1),
			I32Add,
			LocalSet(writeIndex),
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(0),
			End,
			End,
			End,
			LocalGet(storage),
			I32Const(0),
			LocalGet(writeIndex),
			StructNew(plan.bytesTypeIndex),
			LocalSet(outputLocal),
			End,
			End
		]);
		return body;
	}

	function dynamicBooleanString(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var boxType = plan.boxedPrimitiveType(Bool),
			body:Array<WasmInstruction> = [LocalGet(valueLocal), RefTest({nullable: false, heap: Type(boxType)}), If(null)];
		body = body.concat([
			LocalGet(valueLocal),
			RefCast({nullable: false, heap: Type(boxType)}),
			StructGet(boxType, 0),
			If(null)
		]);
		body = body.concat(stringLiteral("true", outputLocal));
		body = body.concat([Else]);
		body = body.concat(stringLiteral("false", outputLocal));
		body = body.concat([End, End]);
		return body;
	}

	function appendTypeTest(body:Array<WasmInstruction>, valueLocal:Int, typeLocal:Int, outputLocal:Int, haxeType:IrType, wasmType:Int):Void {
		body.push(LocalGet(typeLocal));
		body.push(I32Const(WasmBackend.typeId(haxeType)));
		body.push(I32Eq);
		body.push(If(null));
		body.push(LocalGet(valueLocal));
		body.push(RefTest({nullable: false, heap: Type(wasmType)}));
		body.push(LocalSet(outputLocal));
		body.push(End);
	}

	function appendArrayTypeTest(body:Array<WasmInstruction>, valueLocal:Int, typeLocal:Int, outputLocal:Int):Void {
		body.push(LocalGet(typeLocal));
		body.push(I32Const(WasmBackend.typeId(Array(Dyn))));
		body.push(I32Eq);
		body.push(If(null));
		body.push(I32Const(0));
		for (arrayType in plan.arrayWrapperTypes()) {
			body.push(LocalGet(valueLocal));
			body.push(RefTest({nullable: false, heap: Type(arrayType)}));
			body.push(I32Or);
		}
		body.push(LocalSet(outputLocal));
		body.push(End);
	}

	function appendInterfaceTypeTest(body:Array<WasmInstruction>, valueLocal:Int, typeLocal:Int, outputLocal:Int, interfaceName:String):Void {
		body.push(LocalGet(typeLocal));
		body.push(I32Const(WasmBackend.typeId(Virtual(interfaceName))));
		body.push(I32Eq);
		body.push(If(null));
		body.push(I32Const(0));
		for (implementorType in plan.interfaceImplementors(interfaceName)) {
			body.push(LocalGet(valueLocal));
			body.push(RefTest({nullable: false, heap: Type(implementorType)}));
			body.push(I32Or);
		}
		body.push(LocalSet(outputLocal));
		body.push(End);
	}

	function dynamicIsObject(valueLocal:Int, outputLocal:Int):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [LocalGet(valueLocal), RefTest({nullable: false, heap: Eq})];
		var primitiveTypes:Array<IrType> = [IrType.I32, IrType.Bool, IrType.I64, IrType.F64, IrType.TypeRef];
		for (type in primitiveTypes)
			body = body.concat([
				LocalGet(valueLocal),
				RefTest({nullable: false, heap: Type(plan.boxedPrimitiveType(type))}),
				I32Eqz,
				I32And
			]);
		body = body.concat([
			LocalGet(valueLocal),
			RefTest({nullable: false, heap: Type(plan.bytesTypeIndex)}),
			I32Eqz,
			I32And,
			LocalGet(valueLocal),
			RefTest({nullable: false, heap: Type(plan.closureTypeIndex)}),
			I32Eqz,
			I32And,
			LocalSet(outputLocal)
		]);
		return body;
	}

	public function virtualCall(output:IrValue, receiver:IrValue, arguments:Array<IrValue>, targets:Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}>, receiverLocal:Int, destination:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		if (targets.length == 0)
			throw 'Wasm GC interface method on ${Std.string(receiver.type)} has no implementations';
		var instructions:Array<WasmInstruction> = [];
		for (index in 0...targets.length) {
			var target = targets[index],
				objectType = plan.objectType(target.typeName);
			if (target.argumentTypes.length != argumentLocals.length + 1)
				throw 'Wasm GC interface target "${target.typeName}" has an incompatible argument count';
			instructions = instructions.concat([
				LocalGet(receiverLocal),
				RefTest({nullable: false, heap: Type(objectType)}),
				If(null),
				LocalGet(receiverLocal),
				RefCast({nullable: false, heap: Type(objectType)})
			]);
			for (argumentIndex in 0...argumentLocals.length)
				instructions = instructions.concat(virtualArgument(arguments[argumentIndex], target.argumentTypes[argumentIndex + 1],
					argumentLocals[argumentIndex]));
			instructions.push(Call(target.functionIndex));
			if (output.type != Void)
				instructions = instructions.concat(virtualResult(output, target.resultType, destination));
			instructions = instructions.concat(index < targets.length - 1 ? [Else] : [Else, Unreachable]);
		}
		for (_ in targets)
			instructions.push(End);
		return instructions;
	}

	function virtualArgument(argument:IrValue, targetType:IrType, sourceLocal:Int):Array<WasmInstruction> {
		if (WasmGcTypePlan.typeKey(argument.type) == WasmGcTypePlan.typeKey(targetType))
			return [LocalGet(sourceLocal)];
		var targetValue = new IrValue(-1, "virtual-argument", targetType),
			temporary = allocateLocal(valueType(targetType)),
			converted:Null<Array<WasmInstruction>> = null;
		switch [argument.type, targetType] {
			case [I32 | Bool | I64 | F64 | TypeRef, Dyn]:
				converted = toDynamic(argument, temporary, sourceLocal);
			case [Dyn, I32 | Bool | I64 | F64 | TypeRef]:
				converted = safeCast(targetValue, argument, temporary, sourceLocal);
			case [I32, Bool] | [Bool, I32]:
				return [LocalGet(sourceLocal)];
			case [I32, F64]:
				return [LocalGet(sourceLocal), F64ConvertI32S];
			case [F64, I32]:
				return [LocalGet(sourceLocal), I32TruncF64S];
			case [_, _]:
				return switch valueType(targetType) {
					case Ref(reference): [LocalGet(sourceLocal), RefCast(reference)];
					case _: throw 'Wasm GC cannot pass ${Std.string(argument.type)} to interface parameter ${Std.string(targetType)}';
				};
		}
		return requireInstructions(converted).concat([LocalGet(temporary)]);
	}

	function virtualResult(output:IrValue, sourceType:IrType, destination:Int):Array<WasmInstruction> {
		if (WasmGcTypePlan.typeKey(output.type) == WasmGcTypePlan.typeKey(sourceType))
			return [LocalSet(destination)];
		var sourceValue = new IrValue(-1, "virtual-result", sourceType),
			temporary = allocateLocal(valueType(sourceType)),
			converted:Null<Array<WasmInstruction>> = null;
		switch [sourceType, output.type] {
			case [I32 | Bool | I64 | F64 | TypeRef, Dyn]:
				converted = toDynamic(sourceValue, destination, temporary);
			case [Dyn, I32 | Bool | I64 | F64 | TypeRef]:
				converted = safeCast(output, sourceValue, destination, temporary);
			case [I32, Bool] | [Bool, I32]:
				return [LocalSet(destination)];
			case [I32, F64]:
				return [LocalSet(temporary), LocalGet(temporary), F64ConvertI32S, LocalSet(destination)];
			case [F64, I32]:
				return [LocalSet(temporary), LocalGet(temporary), I32TruncF64S, LocalSet(destination)];
			case [_, _]:
				return switch [valueType(sourceType), valueType(output.type)] {
					case [Ref(_), Ref(_)]: [LocalSet(destination)];
					case _: throw 'Wasm GC cannot return ${Std.string(sourceType)} from interface method as ${Std.string(output.type)}';
				};
		}
		return [LocalSet(temporary)].concat(requireInstructions(converted));
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
		if (name == "Math.mathIsNaN" || name == "__math_is_nan") {
			if (output.type != Bool || arguments.length != 1 || arguments[0].type != F64 || argumentLocals.length != 1)
				throw 'Invalid Wasm GC $name signature';
			return [
				LocalGet(argumentLocals[0]),
				LocalGet(argumentLocals[0]),
				F64Eq,
				I32Eqz,
				LocalSet(outputLocal)
			];
		}
		var bytesInput = lowerBytesInputRuntimeCall(name, output, arguments, outputLocal, argumentLocals);
		if (bytesInput != null)
			return bytesInput;
		var bytesOutput = lowerBytesOutputRuntimeCall(name, output, arguments, outputLocal, argumentLocals);
		if (bytesOutput != null)
			return bytesOutput;
		if (name == "__math_ceil") {
			if (output.type != I32 || arguments.length != 1 || arguments[0].type != F64 || argumentLocals.length != 1)
				throw "Invalid Wasm GC Math.ceil signature";
			return [LocalGet(argumentLocals[0]), F64Ceil, I32TruncF64S, LocalSet(outputLocal)];
		}
		if (name == "__std_int_f64") {
			if (output.type != I32 || arguments.length != 1 || arguments[0].type != F64 || argumentLocals.length != 1)
				throw "Invalid Wasm GC Std.int(Float) signature";
			return [LocalGet(argumentLocals[0]), I32TruncF64S, LocalSet(outputLocal)];
		}
		if (name == "__std_int_dynamic") {
			if (output.type != I32 || arguments.length != 1 || arguments[0].type != Dyn || argumentLocals.length != 1)
				throw "Invalid Wasm GC Std.int(Dynamic) signature";
			return dynamicInt(argumentLocals[0], outputLocal);
		}
		if (name == "__std_string") {
			if (output.type != Bytes || arguments.length != 1 || arguments[0].type != Dyn || argumentLocals.length != 1)
				throw "Invalid Wasm GC Std.string signature";
			return dynamicString(argumentLocals[0], outputLocal);
		}
		if (name == "__std_is_of_type" || name == "__exception_matches") {
			if (output.type != Bool || arguments.length != 2 || arguments[0].type != Dyn || arguments[1].type != TypeRef || argumentLocals.length != 2)
				throw 'Invalid Wasm GC $name signature';
			return dynamicTypeTest(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__reflect_is_object") {
			if (output.type != Bool || arguments.length != 1 || arguments[0].type != Dyn || argumentLocals.length != 1)
				throw "Invalid Wasm GC Reflect.isObject signature";
			return dynamicIsObject(argumentLocals[0], outputLocal);
		}
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
		if (name == "__bytes_get_i32" || name == "getI32") {
			if (output.type != I32 || arguments.length != 2 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || argumentLocals.length != 2)
				throw "Invalid Wasm GC Bytes.getInt32 signature";
			return managedByteGetI32(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__bytes_set_i32" || name == "setI32") {
			if (output.type != Void || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32 || arguments[2].type != I32
				|| argumentLocals.length != 3)
				throw "Invalid Wasm GC Bytes.setInt32 signature";
			return managedByteSetI32(argumentLocals[0], argumentLocals[1], argumentLocals[2]);
		}
		if (name == "__bytes_view" || name == "structSlice" || name == "__bytes_sub") {
			if (output.type != ManagedBytes || arguments.length != 3 || arguments[0].type != ManagedBytes || arguments[1].type != I32
				|| arguments[2].type != I32 || argumentLocals.length != 3)
				throw 'Invalid Wasm GC $name signature';
			return name == "__bytes_view"
				|| name == "structSlice" ? managedBytesView(argumentLocals[0], argumentLocals[1], argumentLocals[2],
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
		if (name == "__string_compare_full") {
			if (output.type != I32 || arguments.length != 2 || argumentLocals.length != 2 || arguments[0].type != Bytes || arguments[1].type != Bytes)
				throw "Invalid Wasm GC full string comparison signature";
			return stringCompare(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__string_split") {
			if (!Type.enumEq(output.type, Array(Bytes))
				|| arguments.length != 2
				|| argumentLocals.length != 2
				|| arguments[0].type != Bytes
				|| arguments[1].type != Bytes)
				throw "Invalid Wasm GC String.split signature";
			return stringSplit(argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (name == "__array_join_bytes") {
			if (output.type != Bytes
				|| arguments.length != 2
				|| argumentLocals.length != 2
				|| requireArrayElement(arguments[0].type) != Bytes
				|| arguments[1].type != Bytes)
				throw "Invalid Wasm GC Array<String>.join signature";
			return arrayJoinBytes(argumentLocals[0], argumentLocals[1], outputLocal);
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
		if (StringTools.startsWith(name, "__array_copy_")) {
			if (arguments.length != 1 || argumentLocals.length != 1)
				throw 'Invalid Wasm GC array copy signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				resultElement = requireArrayElement(output.type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_copy_" + suffix || WasmGcTypePlan.typeKey(resultElement) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array copy "$name" does not match its $element array';
			return arrayCopy(element, argumentLocals[0], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_concat_")) {
			if (arguments.length != 2 || argumentLocals.length != 2)
				throw 'Invalid Wasm GC array concat signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				resultElement = requireArrayElement(output.type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_concat_" + suffix
				|| WasmGcTypePlan.typeKey(requireArrayElement(arguments[1].type)) != WasmGcTypePlan.typeKey(element)
				|| WasmGcTypePlan.typeKey(resultElement) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array concat "$name" does not match its $element arrays';
			return arrayConcat(element, argumentLocals[0], argumentLocals[1], outputLocal);
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
		if (StringTools.startsWith(name, "__array_unshift_")) {
			if (arguments.length != 2 || argumentLocals.length != 2 || output.type != I32)
				throw 'Invalid Wasm GC array unshift signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_unshift_" + suffix || WasmGcTypePlan.typeKey(arguments[1].type) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array unshift "$name" does not match its $element array';
			return arrayUnshift(element, argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_insert_")) {
			if (arguments.length != 3 || argumentLocals.length != 3 || output.type != Void || arguments[1].type != I32)
				throw 'Invalid Wasm GC array insert signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_insert_" + suffix || WasmGcTypePlan.typeKey(arguments[2].type) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array insert "$name" does not match its $element array';
			return arrayInsert(element, argumentLocals[0], argumentLocals[1], argumentLocals[2]);
		}
		if (StringTools.startsWith(name, "__array_pop_")) {
			if (arguments.length != 1 || argumentLocals.length != 1)
				throw 'Invalid Wasm GC array pop signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_pop_" + suffix)
				throw 'Wasm GC array pop "$name" does not match its $element array';
			return arrayPop(element, argumentLocals[0], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_reverse_")) {
			if (arguments.length != 1 || argumentLocals.length != 1 || output.type != Void)
				throw 'Invalid Wasm GC array reverse signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_reverse_" + suffix)
				throw 'Wasm GC array reverse "$name" does not match its $element array';
			return arrayReverse(element, argumentLocals[0]);
		}
		if (StringTools.startsWith(name, "__array_resize_")) {
			if (arguments.length != 2 || argumentLocals.length != 2 || output.type != Void || arguments[1].type != I32)
				throw 'Invalid Wasm GC array resize signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_resize_" + suffix)
				throw 'Wasm GC array resize "$name" does not match its $element array';
			return arrayResize(element, argumentLocals[0], argumentLocals[1]);
		}
		if (StringTools.startsWith(name, "__array_shift_")) {
			if (arguments.length != 1 || argumentLocals.length != 1)
				throw 'Invalid Wasm GC array shift signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_shift_" + suffix || WasmGcTypePlan.typeKey(output.type) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array shift "$name" does not match its $element array';
			return arrayShift(element, argumentLocals[0], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_splice_")) {
			if (arguments.length != 3 || argumentLocals.length != 3)
				throw 'Invalid Wasm GC array splice signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				resultElement = requireArrayElement(output.type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_splice_" + suffix)
				throw 'Wasm GC array splice "$name" does not match its $element input array';
			if (arguments[1].type != I32 || arguments[2].type != I32)
				throw 'Wasm GC array splice "$name" requires I32 bounds, got ${Std.string(arguments[1].type)} and ${Std.string(arguments[2].type)}';
			return arraySplice(element, resultElement, argumentLocals[0], argumentLocals[1], argumentLocals[2], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_remove_")) {
			if (arguments.length != 2 || argumentLocals.length != 2 || output.type != Bool)
				throw 'Invalid Wasm GC array remove signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_remove_" + suffix || WasmGcTypePlan.typeKey(arguments[1].type) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array remove "$name" does not match its $element array';
			return arrayRemove(element, argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_index_of_")) {
			if (arguments.length != 2 || argumentLocals.length != 2 || output.type != I32)
				throw 'Invalid Wasm GC array indexOf signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_index_of_" + suffix || WasmGcTypePlan.typeKey(arguments[1].type) != WasmGcTypePlan.typeKey(element))
				throw 'Wasm GC array indexOf "$name" does not match its $element array';
			return arrayIndexOf(element, argumentLocals[0], argumentLocals[1], outputLocal);
		}
		if (StringTools.startsWith(name, "__array_slice_")) {
			if (arguments.length != 3 || argumentLocals.length != 3)
				throw 'Invalid Wasm GC array slice signature for "$name"';
			var element = requireArrayElement(arguments[0].type),
				suffix = arrayNativeSuffix(element);
			if (name != "__array_slice_" + suffix
				|| WasmGcTypePlan.typeKey(requireArrayElement(output.type)) != WasmGcTypePlan.typeKey(element)
				|| arguments[1].type != I32
				|| arguments[2].type != I32)
				throw 'Wasm GC array slice "$name" does not match its $element array';
			return arraySlice(element, argumentLocals[0], argumentLocals[1], argumentLocals[2], outputLocal);
		}
		return null;
	}

	function lowerBytesInputRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		switch name {
			case "__bytes_input_new":
				if (!isNamedAbstract(output.type, "realtime_bytes_input")
					|| arguments.length != 1
					|| arguments[0].type != ManagedBytes
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesInput constructor signature";
				var length = allocateLocal(I32),
					storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
					snapshot = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)}));
				return [
					LocalGet(argumentLocals[0]),
					StructGet(plan.managedBytesTypeIndex, 2),
					LocalSet(length),
					LocalGet(length),
					ArrayNewDefault(plan.byteArrayTypeIndex),
					LocalSet(storage),
					LocalGet(storage),
					I32Const(0),
					LocalGet(argumentLocals[0]),
					StructGet(plan.managedBytesTypeIndex, 0),
					LocalGet(argumentLocals[0]),
					StructGet(plan.managedBytesTypeIndex, 1),
					LocalGet(length),
					ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
					LocalGet(storage),
					I32Const(0),
					LocalGet(length),
					StructNew(plan.managedBytesTypeIndex),
					LocalSet(snapshot),
					LocalGet(snapshot),
					I32Const(0),
					I32Const(1),
					StructNew(plan.bytesInputTypeIndex),
					LocalSet(outputLocal)
				];
			case "__bytes_input_position", "__bytes_input_big_endian":
				if ((name == "__bytes_input_position" && output.type != I32)
					|| (name == "__bytes_input_big_endian" && output.type != Bool)
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| argumentLocals.length != 1)
					throw 'Invalid Wasm GC $name signature';
				return [
					LocalGet(argumentLocals[0]),
					RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
					StructGet(plan.bytesInputTypeIndex, name == "__bytes_input_position" ? 1 : 2),
					LocalSet(outputLocal)
				];
			case "__bytes_input_set_big_endian":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| arguments[1].type != Bool
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesInput endian setter signature";
				return [
					LocalGet(argumentLocals[0]),
					RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
					LocalGet(argumentLocals[1]),
					StructSet(plan.bytesInputTypeIndex, 2)
				];
			case "__bytes_input_read_byte":
				if (output.type != I32
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesInput.readByte signature";
				var bytes = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)})),
					position = allocateLocal(I32),
					body:Array<WasmInstruction> = inputReadLocals(argumentLocals[0], bytes, position, null);
				body = body.concat(managedByteGet(bytes, position, outputLocal));
				body = body.concat(inputAdvanceConstant(argumentLocals[0], position, 1));
				return body;
			case "__bytes_input_read_i32":
				if (output.type != I32
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesInput.readInt32 signature";
				var bytes = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)})),
					position = allocateLocal(I32),
					endian = allocateLocal(I32),
					byteLocals = [for (_ in 0...4) allocateLocal(I32)],
					body:Array<WasmInstruction> = inputReadLocals(argumentLocals[0], bytes, position, endian);
				for (index in 0...4) {
					var byteIndex = allocateLocal(I32);
					body = body.concat([LocalGet(position), I32Const(index), I32Add, LocalSet(byteIndex)]);
					body = body.concat(managedByteGet(bytes, byteIndex, byteLocals[index]));
				}
				body = body.concat(combineInputBytes(byteLocals, endian, false, outputLocal));
				body = body.concat(inputAdvanceConstant(argumentLocals[0], position, 4));
				return body;
			case "__bytes_input_read_f64":
				if (output.type != F64
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesInput.readDouble signature";
				var bytes = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)})),
					position = allocateLocal(I32),
					endian = allocateLocal(I32),
					bits = allocateLocal(I64),
					byteLocals = [for (_ in 0...8) allocateLocal(I32)],
					body:Array<WasmInstruction> = inputReadLocals(argumentLocals[0], bytes, position, endian);
				for (index in 0...8) {
					var byteIndex = allocateLocal(I32);
					body = body.concat([LocalGet(position), I32Const(index), I32Add, LocalSet(byteIndex)]);
					body = body.concat(managedByteGet(bytes, byteIndex, byteLocals[index]));
				}
				body = body.concat(combineInputBytes(byteLocals, endian, true, bits));
				body = body.concat([LocalGet(bits), F64ReinterpretI64, LocalSet(outputLocal)]);
				body = body.concat(inputAdvanceConstant(argumentLocals[0], position, 8));
				return body;
			case "__bytes_input_read_string":
				if (output.type != Bytes
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| arguments[1].type != I32
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesInput.readString signature";
				var bytes = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)})),
					position = allocateLocal(I32),
					body:Array<WasmInstruction> = inputReadLocals(argumentLocals[0], bytes, position, null);
				body = body.concat(managedBytesGetString(bytes, position, argumentLocals[1], outputLocal));
				body = body.concat(inputAdvance(argumentLocals[0], position, argumentLocals[1]));
				return body;
			case "__bytes_input_read":
				if (output.type != ManagedBytes
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_input")
					|| arguments[1].type != I32
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesInput.read signature";
				var source = allocateLocal(Ref({nullable: false, heap: Type(plan.managedBytesTypeIndex)})),
					position = allocateLocal(I32),
					length = argumentLocals[1],
					storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
					body:Array<WasmInstruction> = inputReadLocals(argumentLocals[0], source, position, null);
				body = body.concat(checkedByteRange(plan.managedBytesTypeIndex, source, position, length));
				body = body.concat([
					LocalGet(length),
					ArrayNewDefault(plan.byteArrayTypeIndex),
					LocalSet(storage),
					LocalGet(storage),
					I32Const(0),
					LocalGet(source),
					StructGet(plan.managedBytesTypeIndex, 0),
					LocalGet(source),
					StructGet(plan.managedBytesTypeIndex, 1),
					LocalGet(position),
					I32Add,
					LocalGet(length),
					ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
					LocalGet(storage),
					I32Const(0),
					LocalGet(length),
					StructNew(plan.managedBytesTypeIndex),
					LocalSet(outputLocal)
				]);
				body = body.concat(inputAdvance(argumentLocals[0], position, length));
				return body;
			default:
				return null;
		}
	}

	function inputReadLocals(inputLocal:Int, bytesLocal:Int, positionLocal:Int, endianLocal:Null<Int>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [
			LocalGet(inputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
			StructGet(plan.bytesInputTypeIndex, 0),
			RefCast({nullable: false, heap: Type(plan.managedBytesTypeIndex)}),
			LocalSet(bytesLocal),
			LocalGet(inputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
			StructGet(plan.bytesInputTypeIndex, 1),
			LocalSet(positionLocal)
		];
		if (endianLocal != null)
			body = body.concat([
				LocalGet(inputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
				StructGet(plan.bytesInputTypeIndex, 2),
				LocalSet(endianLocal)
			]);
		return body;
	}

	function inputAdvance(inputLocal:Int, positionLocal:Int, amountLocal:Int):Array<WasmInstruction> {
		return [
			LocalGet(inputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
			LocalGet(positionLocal),
			LocalGet(amountLocal),
			I32Add,
			StructSet(plan.bytesInputTypeIndex, 1)
		];
	}

	function inputAdvanceConstant(inputLocal:Int, positionLocal:Int, amount:Int):Array<WasmInstruction> {
		return [
			LocalGet(inputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesInputTypeIndex)}),
			LocalGet(positionLocal),
			I32Const(amount),
			I32Add,
			StructSet(plan.bytesInputTypeIndex, 1)
		];
	}

	function combineInputBytes(bytes:Array<Int>, endian:Int, wide:Bool, destination:Int):Array<WasmInstruction> {
		var width = wide ? I64 : I32,
			body:Array<WasmInstruction> = [LocalGet(endian), If(width)];
		body = body.concat(combineInputByteOrder(bytes, wide, true));
		body.push(Else);
		body = body.concat(combineInputByteOrder(bytes, wide, false));
		body = body.concat([End, LocalSet(destination)]);
		return body;
	}

	function combineInputByteOrder(bytes:Array<Int>, wide:Bool, bigEndian:Bool):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [],
			indices = bigEndian ? [for (index in 0...bytes.length) index] : [for (index in 0...bytes.length) bytes.length - index - 1], first = true;
		for (index in indices) {
			if (!first) {
				body.push(wide ? I64Const(8) : I32Const(8));
				body.push(wide ? I64Shl : I32Shl);
			}
			body.push(LocalGet(bytes[index]));
			if (wide)
				body.push(I64ExtendI32U);
			if (!first)
				body.push(wide ? I64Or : I32Or);
			first = false;
		}
		return body;
	}

	function lowerBytesOutputRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
		switch name {
			case "__bytes_output_new":
				if (!isNamedAbstract(output.type, "realtime_bytes_output") || arguments.length != 0 || argumentLocals.length != 0)
					throw 'Invalid Wasm GC BytesOutput constructor signature: output=${Std.string(output.type)}, arguments=${arguments.length}, locals=${argumentLocals.length}';
				return [
					I32Const(0),
					I32Const(0),
					I32Const(0),
					ArrayNewDefault(plan.byteArrayTypeIndex),
					I32Const(1),
					StructNew(plan.bytesOutputTypeIndex),
					LocalSet(outputLocal)
				];
			case "__bytes_output_big_endian":
				if (output.type != Bool
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesOutput endian getter signature";
				return [
					LocalGet(argumentLocals[0]),
					RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
					StructGet(plan.bytesOutputTypeIndex, 3),
					LocalSet(outputLocal)
				];
			case "__bytes_output_set_big_endian":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != Bool
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput endian setter signature";
				return [
					LocalGet(argumentLocals[0]),
					RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
					LocalGet(argumentLocals[1]),
					StructSet(plan.bytesOutputTypeIndex, 3)
				];
			case "__bytes_output_write_byte":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != I32
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput.writeByte signature";
				return outputWriteByte(argumentLocals[0], argumentLocals[1]);
			case "__bytes_output_write_i32":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != I32
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput.writeInt32 signature";
				return outputWriteI32(argumentLocals[0], argumentLocals[1]);
			case "__bytes_output_write_f64":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != F64
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput.writeDouble signature";
				return outputWriteF64(argumentLocals[0], argumentLocals[1]);
			case "__bytes_output_write_string":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != Bytes
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput.writeString signature";
				var offset = allocateLocal(I32),
					length = allocateLocal(I32),
					body:Array<WasmInstruction> = [LocalGet(argumentLocals[1]), RefIsNull, If(null)];
				body.push(Else);
				body = body.concat([
					LocalGet(argumentLocals[1]),
					StructGet(plan.bytesTypeIndex, 1),
					LocalSet(offset),
					LocalGet(argumentLocals[1]),
					StructGet(plan.bytesTypeIndex, 2),
					LocalSet(length)
				]);
				body = body.concat(outputAppendRange(argumentLocals[0], plan.bytesTypeIndex, argumentLocals[1], offset, length));
				body.push(End);
				return body;
			case "__bytes_output_write":
				if (output.type != Void
					|| arguments.length != 2
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != ManagedBytes
					|| argumentLocals.length != 2)
					throw "Invalid Wasm GC BytesOutput.write signature";
				var offset = allocateLocal(I32),
					length = allocateLocal(I32),
					body:Array<WasmInstruction> = [
						I32Const(0),
						LocalSet(offset),
						LocalGet(argumentLocals[1]),
						StructGet(plan.managedBytesTypeIndex, 2),
						LocalSet(length)
					];
				return body.concat(outputAppendRange(argumentLocals[0], plan.managedBytesTypeIndex, argumentLocals[1], offset, length));
			case "__bytes_output_write_range":
				if (output.type != I32
					|| arguments.length != 4
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| arguments[1].type != ManagedBytes
					|| arguments[2].type != I32
					|| arguments[3].type != I32
					|| argumentLocals.length != 4)
					throw "Invalid Wasm GC BytesOutput.writeBytes signature";
				var body = outputAppendRange(argumentLocals[0], plan.managedBytesTypeIndex, argumentLocals[1], argumentLocals[2], argumentLocals[3]);
				body = body.concat([LocalGet(argumentLocals[3]), LocalSet(outputLocal)]);
				return body;
			case "__bytes_output_get_bytes":
				if (output.type != ManagedBytes
					|| arguments.length != 1
					|| !isNamedAbstract(arguments[0].type, "realtime_bytes_output")
					|| argumentLocals.length != 1)
					throw "Invalid Wasm GC BytesOutput.getBytes signature";
				var length = allocateLocal(I32),
					storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)}));
				return [
					LocalGet(argumentLocals[0]),
					RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
					StructGet(plan.bytesOutputTypeIndex, 0),
					LocalSet(length),
					LocalGet(length),
					ArrayNewDefault(plan.byteArrayTypeIndex),
					LocalSet(storage),
					LocalGet(storage),
					I32Const(0),
					LocalGet(argumentLocals[0]),
					RefCast({
						nullable: false,
						heap: Type(plan.bytesOutputTypeIndex)
					}),
					StructGet(plan.bytesOutputTypeIndex, 2),
					I32Const(0),
					LocalGet(length),
					ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
					LocalGet(storage),
					I32Const(0),
					LocalGet(length),
					StructNew(plan.managedBytesTypeIndex),
					LocalSet(outputLocal)
				];
			default:
				return null;
		}
	}

	function outputWriteByte(outputLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			required = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 0),
				LocalSet(length),
				LocalGet(length),
				I32Const(1),
				I32Add,
				LocalSet(required)
			];
		body = body.concat(outputEnsureCapacity(outputLocal, required));
		body = body.concat([
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			StructGet(plan.bytesOutputTypeIndex, 2),
			LocalGet(length),
			LocalGet(valueLocal),
			ArraySet(plan.byteArrayTypeIndex),
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			LocalGet(required),
			StructSet(plan.bytesOutputTypeIndex, 0)
		]);
		return body;
	}

	function outputWriteI32(outputLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			required = allocateLocal(I32),
			endian = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(outputLocal),
				RefCast({
					nullable: false,
					heap: Type(plan.bytesOutputTypeIndex)
				}),
				StructGet(plan.bytesOutputTypeIndex, 0),
				LocalSet(length),
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 3),
				LocalSet(endian),
				LocalGet(length),
				I32Const(4),
				I32Add,
				LocalSet(required)
			];
		body = body.concat(outputEnsureCapacity(outputLocal, required));
		for (index in 0...4) {
			body = body.concat([
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 2),
				LocalGet(length),
				I32Const(index),
				I32Add,
				LocalGet(valueLocal),
				LocalGet(endian),
				If(I32),
				I32Const(24 - index * 8),
				Else,
				I32Const(index * 8),
				End,
				I32ShrU,
				I32Const(255),
				I32And,
				ArraySet(plan.byteArrayTypeIndex)
			]);
		}
		body = body.concat([
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			LocalGet(required),
			StructSet(plan.bytesOutputTypeIndex, 0)
		]);
		return body;
	}

	function outputWriteF64(outputLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			required = allocateLocal(I32),
			endian = allocateLocal(I32),
			bits = allocateLocal(I64),
			body:Array<WasmInstruction> = [
				LocalGet(valueLocal),
				I64ReinterpretF64,
				LocalSet(bits),
				LocalGet(outputLocal),
				RefCast({
					nullable: false,
					heap: Type(plan.bytesOutputTypeIndex)
				}),
				StructGet(plan.bytesOutputTypeIndex, 0),
				LocalSet(length),
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 3),
				LocalSet(endian),
				LocalGet(length),
				I32Const(8),
				I32Add,
				LocalSet(required)
			];
		body = body.concat(outputEnsureCapacity(outputLocal, required));
		for (index in 0...8) {
			body = body.concat([
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 2),
				LocalGet(length),
				I32Const(index),
				I32Add,
				LocalGet(bits),
				LocalGet(endian),
				If(I64),
				I64Const(56 - index * 8),
				Else,
				I64Const(index * 8),
				End,
				I64ShrU,
				I32WrapI64,
				I32Const(255),
				I32And,
				ArraySet(plan.byteArrayTypeIndex)
			]);
		}
		body = body.concat([
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			LocalGet(required),
			StructSet(plan.bytesOutputTypeIndex, 0)
		]);
		return body;
	}

	function outputAppendRange(outputLocal:Int, sourceType:Int, sourceLocal:Int, sourceOffsetLocal:Int, sourceLengthLocal:Int):Array<WasmInstruction> {
		var outputOffset = allocateLocal(I32),
			required = allocateLocal(I32),
			body = checkedByteRange(sourceType, sourceLocal, sourceOffsetLocal, sourceLengthLocal);
		body = body.concat([
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			StructGet(plan.bytesOutputTypeIndex, 0),
			LocalSet(outputOffset),
			LocalGet(outputOffset),
			LocalGet(sourceLengthLocal),
			I32Add,
			LocalSet(required)
		]);
		body = body.concat(outputEnsureCapacity(outputLocal, required));
		body = body.concat([
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			StructGet(plan.bytesOutputTypeIndex, 2),
			LocalGet(outputOffset),
			LocalGet(sourceLocal),
			StructGet(sourceType, 0),
			LocalGet(sourceLocal),
			StructGet(sourceType, 1),
			LocalGet(sourceOffsetLocal),
			I32Add,
			LocalGet(sourceLengthLocal),
			ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
			LocalGet(outputLocal),
			RefCast({
				nullable: false,
				heap: Type(plan.bytesOutputTypeIndex)
			}),
			LocalGet(required),
			StructSet(plan.bytesOutputTypeIndex, 0)
		]);
		return body;
	}

	function outputEnsureCapacity(outputLocal:Int, requiredLocal:Int):Array<WasmInstruction> {
		var capacity = allocateLocal(I32),
			newCapacity = allocateLocal(I32),
			oldLength = allocateLocal(I32),
			oldStorage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			newStorage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			body:Array<WasmInstruction> = [
				LocalGet(outputLocal),
				RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
				StructGet(plan.bytesOutputTypeIndex, 1),
				LocalSet(capacity),
				LocalGet(requiredLocal),
				LocalGet(capacity),
				I32LeS,
				If(null)
			];
		body.push(Else);
		body = body.concat([
			LocalGet(capacity),
			I32Eqz,
			If(null),
			LocalGet(requiredLocal),
			LocalSet(newCapacity),
			Else,
			LocalGet(capacity),
			I32Const(2),
			I32Mul,
			LocalSet(newCapacity),
			LocalGet(newCapacity),
			LocalGet(requiredLocal),
			I32LtS,
			If(null),
			LocalGet(requiredLocal),
			LocalSet(newCapacity),
			End,
			End,
			LocalGet(outputLocal),
			RefCast({
				nullable: false,
				heap: Type(plan.bytesOutputTypeIndex)
			}),
			StructGet(plan.bytesOutputTypeIndex, 0),
			LocalSet(oldLength),
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			StructGet(plan.bytesOutputTypeIndex, 2),
			LocalSet(oldStorage),
			LocalGet(newCapacity),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(newStorage),
			LocalGet(newStorage),
			I32Const(0),
			LocalGet(oldStorage),
			I32Const(0),
			LocalGet(oldLength),
			ArrayCopy(plan.byteArrayTypeIndex, plan.byteArrayTypeIndex),
			LocalGet(outputLocal),
			RefCast({
				nullable: false,
				heap: Type(plan.bytesOutputTypeIndex)
			}),
			LocalGet(newCapacity),
			StructSet(plan.bytesOutputTypeIndex, 1),
			LocalGet(outputLocal),
			RefCast({nullable: false, heap: Type(plan.bytesOutputTypeIndex)}),
			LocalGet(newStorage),
			StructSet(plan.bytesOutputTypeIndex, 2),
			End
		]);
		return body;
	}

	function arrayIndexOf(element:IrType, arrayLocal:Int, valueLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			index = allocateLocal(I32),
			value = allocateLocal(valueType(element)),
			equal = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				I32Const(0),
				LocalSet(index),
				I32Const(-1),
				LocalSet(destination),
				Loop(null),
				LocalGet(index),
				LocalGet(length),
				I32LtS,
				If(null),
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalGet(index),
				ArrayGet(storageType),
				LocalSet(value)
			];
		body = body.concat(arrayValueEqual(element, value, valueLocal, equal));
		body = body.concat([
			LocalGet(equal),
			If(null),
			LocalGet(destination),
			I32Const(-1),
			I32Eq,
			If(null),
			LocalGet(index),
			LocalSet(destination),
			End,
			End,
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(1),
			End,
			End
		]);
		return body;
	}

	function arrayValueEqual(element:IrType, left:Int, right:Int, destination:Int):Array<WasmInstruction> {
		if (element == Bytes) {
			var body:Array<WasmInstruction> = [
				LocalGet(left),
				LocalGet(right),
				RefEq,
				LocalSet(destination),
				LocalGet(destination),
				I32Eqz,
				If(null),
				LocalGet(left),
				RefIsNull,
				If(null),
				LocalGet(right),
				RefIsNull,
				LocalSet(destination),
				Else,
				LocalGet(right),
				RefIsNull,
				If(null),
				I32Const(0),
				LocalSet(destination),
				Else
			];
			body = body.concat(bytesEqual(destination, left, right));
			body = body.concat([End, End, End]);
			return body;
		}
		var comparison = switch valueType(element) {
			case F64: F64Eq;
			case I64: I64Eq;
			case Ref(_): RefEq;
			default: I32Eq;
		};
		return [LocalGet(left), LocalGet(right), comparison, LocalSet(destination)];
	}

	function arraySlice(element:IrType, arrayLocal:Int, startArgument:Int, endArgument:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			start = allocateLocal(I32),
			end = allocateLocal(I32),
			resultLength = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(startArgument),
				LocalSet(start),
				LocalGet(endArgument),
				LocalSet(end)
			];
		body = body.concat(normalizeSliceBound(start, length));
		body = body.concat(normalizeSliceBound(end, length));
		body = body.concat([
			LocalGet(end),
			LocalGet(start),
			I32LtS,
			If(null),
			LocalGet(start),
			LocalSet(end),
			End,
			LocalGet(end),
			LocalGet(start),
			I32Sub,
			LocalSet(resultLength),
			LocalGet(resultLength),
			ArrayNewDefault(storageType),
			LocalSet(storage),
			LocalGet(storage),
			I32Const(0),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(start),
			LocalGet(resultLength),
			ArrayCopy(storageType, storageType),
			LocalGet(resultLength),
			LocalGet(storage),
			StructNew(wrapperType),
			LocalSet(destination)
		]);
		return body;
	}

	function arrayCopy(element:IrType, arrayLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			length = allocateLocal(I32),
			start = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				I32Const(0),
				LocalSet(start)
			];
		return body.concat(arraySlice(element, arrayLocal, start, length, destination));
	}

	function arrayConcat(element:IrType, leftLocal:Int, rightLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			leftLength = allocateLocal(I32),
			rightLength = allocateLocal(I32),
			totalLength = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			body:Array<WasmInstruction> = [
				LocalGet(leftLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(leftLength),
				LocalGet(rightLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(rightLength),
				LocalGet(leftLength),
				LocalGet(rightLength),
				I32Add,
				LocalSet(totalLength),
				LocalGet(totalLength),
				ArrayNewDefault(storageType),
				LocalSet(storage),
				LocalGet(storage),
				I32Const(0),
				LocalGet(leftLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				I32Const(0),
				LocalGet(leftLength),
				ArrayCopy(storageType, storageType),
				LocalGet(storage),
				LocalGet(leftLength),
				LocalGet(rightLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				I32Const(0),
				LocalGet(rightLength),
				ArrayCopy(storageType, storageType),
				LocalGet(totalLength),
				LocalGet(storage),
				StructNew(wrapperType),
				LocalSet(destination)
			];
		return body;
	}

	function arrayPop(element:IrType, arrayLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			newLength = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(length),
				I32Eqz,
				If(null)
			];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalSet(storage),
			LocalGet(length),
			I32Const(1),
			I32Sub,
			LocalSet(newLength),
			LocalGet(storage),
			LocalGet(newLength),
			ArrayGet(storageType),
			LocalSet(destination),
			LocalGet(storage),
			LocalGet(newLength)
		]);
		body = body.concat(zeroValue(element));
		body = body.concat([
			ArraySet(storageType),
			LocalGet(arrayLocal),
			LocalGet(newLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex())
		]);
		return body;
	}

	function arrayReverse(element:IrType, arrayLocal:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			left = allocateLocal(I32),
			right = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			leftValue = allocateLocal(valueType(element)),
			rightValue = allocateLocal(valueType(element)),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				I32Const(0),
				LocalSet(left),
				LocalGet(length),
				I32Const(1),
				I32Sub,
				LocalSet(right),
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalSet(storage),
				Loop(null),
				LocalGet(left),
				LocalGet(right),
				I32LtS,
				If(null),
				LocalGet(storage),
				LocalGet(left),
				ArrayGet(storageType),
				LocalSet(leftValue),
				LocalGet(storage),
				LocalGet(right),
				ArrayGet(storageType),
				LocalSet(rightValue),
				LocalGet(storage),
				LocalGet(left),
				LocalGet(rightValue),
				ArraySet(storageType),
				LocalGet(storage),
				LocalGet(right),
				LocalGet(leftValue),
				ArraySet(storageType),
				LocalGet(left),
				I32Const(1),
				I32Add,
				LocalSet(left),
				LocalGet(right),
				I32Const(1),
				I32Sub,
				LocalSet(right),
				Br(1),
				End,
				End
			];
		return body;
	}

	function arrayUnshift(element:IrType, arrayLocal:Int, valueLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			requiredLength = allocateLocal(I32),
			capacity = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			newStorage = allocateLocal(Ref({nullable: false, heap: Type(storageType)})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalSet(storage),
				LocalGet(length),
				I32Const(1),
				I32Add,
				LocalSet(requiredLength),
				LocalGet(storage),
				ArrayLen,
				LocalSet(capacity),
				LocalGet(capacity),
				LocalGet(requiredLength),
				I32LtS,
				If(null),
				LocalGet(capacity),
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
				LocalSet(newStorage),
				LocalGet(newStorage),
				I32Const(0),
				LocalGet(storage),
				I32Const(0),
				LocalGet(length),
				ArrayCopy(storageType, storageType),
				LocalGet(newStorage),
				LocalSet(storage),
				End,
				LocalGet(storage),
				I32Const(1),
				LocalGet(storage),
				I32Const(0),
				LocalGet(length),
				ArrayCopy(storageType, storageType),
				LocalGet(storage),
				I32Const(0),
				LocalGet(valueLocal),
				ArraySet(storageType),
				LocalGet(arrayLocal),
				LocalGet(storage),
				StructSet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalGet(arrayLocal),
				LocalGet(requiredLength),
				StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalGet(requiredLength),
				LocalSet(destination)
			];
		return body;
	}

	function arrayInsert(element:IrType, arrayLocal:Int, indexArgument:Int, valueLocal:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			index = allocateLocal(I32),
			start = allocateLocal(I32),
			requiredLength = allocateLocal(I32),
			capacity = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			newStorage = allocateLocal(Ref({nullable: false, heap: Type(storageType)})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(indexArgument),
				LocalSet(index),
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalSet(storage),
				LocalGet(index),
				I32Const(0),
				I32LtS,
				If(null),
				I32Const(0),
				LocalSet(index),
				End,
				LocalGet(length),
				LocalGet(index),
				I32LtS,
				If(null),
				LocalGet(length),
				LocalSet(index),
				End,
				LocalGet(index),
				LocalSet(start),
				LocalGet(length),
				I32Const(1),
				I32Add,
				LocalSet(requiredLength),
				LocalGet(storage),
				ArrayLen,
				LocalSet(capacity),
				LocalGet(capacity),
				LocalGet(requiredLength),
				I32LtS,
				If(null),
				LocalGet(capacity),
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
				LocalSet(newStorage),
				LocalGet(newStorage),
				I32Const(0),
				LocalGet(storage),
				I32Const(0),
				LocalGet(length),
				ArrayCopy(storageType, storageType),
				LocalGet(newStorage),
				LocalSet(storage),
				End,
				LocalGet(length),
				LocalSet(index),
				Loop(null),
				LocalGet(start),
				LocalGet(index),
				I32LtS,
				If(null),
				LocalGet(index),
				I32Const(1),
				I32Sub,
				LocalSet(index),
				LocalGet(storage),
				LocalGet(index),
				I32Const(1),
				I32Add,
				LocalGet(storage),
				LocalGet(index),
				I32Const(1),
				ArrayCopy(storageType, storageType),
				Br(1),
				End,
				End,
				LocalGet(storage),
				LocalGet(index),
				LocalGet(valueLocal),
				ArraySet(storageType),
				LocalGet(arrayLocal),
				LocalGet(storage),
				StructSet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
				LocalGet(arrayLocal),
				LocalGet(requiredLength),
				StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex())
			];
		return body;
	}

	function arrayResize(element:IrType, arrayLocal:Int, requestedLength:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			capacity = allocateLocal(I32),
			index = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			newStorage = allocateLocal(Ref({nullable: false, heap: Type(storageType)})),
			body:Array<WasmInstruction> = [LocalGet(requestedLength), I32Const(0), I32LtS, If(null)];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			LocalSet(length),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalSet(storage),
			LocalGet(storage),
			ArrayLen,
			LocalSet(capacity),
			LocalGet(requestedLength),
			LocalGet(capacity),
			I32LeS,
			If(null),
			LocalGet(length),
			LocalGet(requestedLength),
			I32LtS,
			If(null),
			LocalGet(length),
			LocalSet(index),
			Loop(null),
			LocalGet(index),
			LocalGet(requestedLength),
			I32LtS,
			If(null),
			LocalGet(storage),
			LocalGet(index)
		]);
		body = body.concat(zeroValue(element));
		body = body.concat([
			ArraySet(storageType),
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(1),
			End,
			End,
			Else,
			LocalGet(requestedLength),
			LocalGet(length),
			I32LtS,
			If(null),
			LocalGet(requestedLength),
			LocalSet(index),
			Loop(null),
			LocalGet(index),
			LocalGet(length),
			I32LtS,
			If(null),
			LocalGet(storage),
			LocalGet(index)
		]);
		body = body.concat(zeroValue(element));
		body = body.concat([
			ArraySet(storageType),
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(1),
			End,
			End,
			End,
			End,
			Else,
			LocalGet(capacity),
			I32Const(2),
			I32Mul,
			LocalSet(capacity),
			LocalGet(capacity),
			LocalGet(requestedLength),
			I32LtS,
			If(null),
			LocalGet(requestedLength),
			LocalSet(capacity),
			End,
			LocalGet(capacity),
			ArrayNewDefault(storageType),
			LocalSet(newStorage),
			LocalGet(newStorage),
			I32Const(0),
			LocalGet(storage),
			I32Const(0),
			LocalGet(length),
			ArrayCopy(storageType, storageType),
			LocalGet(arrayLocal),
			LocalGet(newStorage),
			StructSet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			End
		]);
		body = body.concat([
			LocalGet(arrayLocal),
			LocalGet(requestedLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex())
		]);
		return body;
	}

	function arrayShift(element:IrType, arrayLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			length = allocateLocal(I32),
			newLength = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(length),
				I32Eqz,
				If(null)
			];
		body = body.concat(trapInstructions());
		body = body.concat([
			End,
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalSet(storage),
			LocalGet(storage),
			I32Const(0),
			ArrayGet(storageType),
			LocalSet(destination),
			LocalGet(length),
			I32Const(1),
			I32Sub,
			LocalSet(newLength),
			LocalGet(storage),
			I32Const(0),
			LocalGet(storage),
			I32Const(1),
			LocalGet(newLength),
			ArrayCopy(storageType, storageType),
			LocalGet(storage),
			LocalGet(newLength)
		]);
		body = body.concat(zeroValue(element));
		body = body.concat([
			ArraySet(storageType),
			LocalGet(arrayLocal),
			LocalGet(newLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex())
		]);
		return body;
	}

	function arraySplice(element:IrType, resultElement:IrType, arrayLocal:Int, startArgument:Int, countArgument:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(element),
			storageType = plan.arrayStorageType(element),
			resultWrapperType = plan.arrayType(resultElement),
			resultStorageType = plan.arrayStorageType(resultElement),
			length = allocateLocal(I32),
			start = allocateLocal(I32),
			count = allocateLocal(I32),
			newLength = allocateLocal(I32),
			tailLength = allocateLocal(I32),
			index = allocateLocal(I32),
			storage = allocateLocal(Ref({
				nullable: false,
				heap: Type(storageType)
			})),
			removedStorage = allocateLocal(Ref({nullable: false, heap: Type(resultStorageType)})),
			removedArray = allocateLocal(Ref({nullable: false, heap: Type(resultWrapperType)})),
			body:Array<WasmInstruction> = [
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				LocalGet(startArgument),
				LocalSet(start)
			];
		body = body.concat(normalizeSliceBound(start, length));
		body = body.concat([
			LocalGet(countArgument),
			LocalSet(count),
			LocalGet(count),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(count),
			End,
			LocalGet(length),
			LocalGet(start),
			I32Sub,
			LocalSet(tailLength),
			LocalGet(tailLength),
			LocalGet(count),
			I32LtS,
			If(null),
			LocalGet(tailLength),
			LocalSet(count),
			End,
			LocalGet(length),
			LocalGet(count),
			I32Sub,
			LocalSet(newLength),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalSet(storage),
			LocalGet(count),
			ArrayNewDefault(resultStorageType),
			LocalSet(removedStorage),
			LocalGet(count),
			LocalGet(removedStorage),
			StructNew(resultWrapperType),
			LocalSet(removedArray),
			LocalGet(removedStorage),
			I32Const(0),
			LocalGet(storage),
			LocalGet(start),
			LocalGet(count),
			ArrayCopy(resultStorageType, storageType),
			LocalGet(length),
			LocalGet(start),
			I32Sub,
			LocalGet(count),
			I32Sub,
			LocalSet(tailLength),
			LocalGet(storage),
			LocalGet(start),
			LocalGet(storage),
			LocalGet(start),
			LocalGet(count),
			I32Add,
			LocalGet(tailLength),
			ArrayCopy(storageType, storageType),
			LocalGet(newLength),
			LocalSet(index),
			Loop(null),
			LocalGet(index),
			LocalGet(length),
			I32LtS,
			If(null),
			LocalGet(storage),
			LocalGet(index)
		]);
		body = body.concat(zeroValue(element));
		body = body.concat([
			ArraySet(storageType),
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(1),
			End,
			End,
			LocalGet(arrayLocal),
			LocalGet(newLength),
			StructSet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			LocalGet(removedArray),
			LocalSet(destination)
		]);
		return body;
	}

	function arrayRemove(element:IrType, arrayLocal:Int, valueLocal:Int, destination:Int):Array<WasmInstruction> {
		var index = allocateLocal(I32),
			count = allocateLocal(I32),
			removedArray = allocateLocal(Ref({nullable: false, heap: Type(plan.arrayType(element))})),
			body = arrayIndexOf(element, arrayLocal, valueLocal, index);
		body = body.concat([
			LocalGet(index),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(destination),
			Else,
			I32Const(1),
			LocalSet(count)
		]);
		body = body.concat(arraySplice(element, element, arrayLocal, index, count, removedArray));
		body = body.concat([I32Const(1), LocalSet(destination), End]);
		return body;
	}

	function normalizeSliceBound(bound:Int, length:Int):Array<WasmInstruction>
		return [
			LocalGet(bound),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(bound),
			LocalGet(length),
			I32Add,
			LocalSet(bound),
			End,
			LocalGet(bound),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(bound),
			Else,
			LocalGet(length),
			LocalGet(bound),
			I32LtS,
			If(null),
			LocalGet(length),
			LocalSet(bound),
			End,
			End
		];

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):Null<Array<WasmInstruction>> {
		var usesScratchBridge = false;
		for (mode in native.argumentModes)
			switch mode {
				case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize:
					usesScratchBridge = true;
				case Value:
				case Output | InputOutput:
					throw 'Wasm GC C native "${native.name}" requires byte-backed pointer directions';
			}
		if (usesScratchBridge && (scratchAllocator < 0 || scratchTop < 0))
			throw 'Wasm GC C native "${native.name}" requires a configured linear scratch bridge';
		var bytePointerResult = native.result == ManagedBytes && native.pointerLength != null;
		if (bytePointerResult && pointerLengthImportIndex < 0)
			throw 'Wasm GC C native "${native.name}" has no imported byte-result length function';
		if (bytePointerResult && native.pointerOwnership == "owned" && pointerReleaseImportIndex < 0)
			throw 'Wasm GC C native "${native.name}" has no imported byte-result release function';
		var body:Array<WasmInstruction> = [],
			savedTop = usesScratchBridge ? allocateLocal(I32) : -1,
			bytePointers:Array<Null<Int>> = [];
		if (usesScratchBridge)
			body = body.concat([GlobalGet(scratchTop), LocalSet(savedTop)]);
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInput(_) | BytesInputOutput(_):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte input $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						Call(scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case BytesOutput(sizeArgument):
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte output $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						sizeLocal = argumentLocals[sizeArgument],
						sizeOffset = allocateLocal(I32),
						capacity = allocateLocal(I32),
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat([
						LocalGet(bytesLocal),
						RefIsNull,
						If(null),
						I32Const(0),
						LocalSet(pointer),
						Else,
						I32Const(0),
						LocalSet(sizeOffset)
					]);
					body = body.concat(requireGcBytesLength(sizeLocal, 4));
					body = body.concat(managedByteGetI32(sizeLocal, sizeOffset, capacity));
					body = body.concat([
						LocalGet(capacity),
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						I32Eq,
						I32Eqz,
						If(null),
						Unreachable,
						End,
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						Call(scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
					body.push(End);
				case BytesSize:
					if (arguments[index].type != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" byte size $index has type ${Std.string(arguments[index].type)}';
					var bytesLocal = argumentLocals[index],
						pointer = allocateLocal(I32);
					bytePointers[index] = pointer;
					body = body.concat(requireGcBytesLength(bytesLocal, 4));
					body = body.concat([
						LocalGet(bytesLocal),
						StructGet(plan.managedBytesTypeIndex, 2),
						Call(scratchAllocator),
						LocalSet(pointer)
					]);
					body = body.concat(copyGcBytesToLinear(bytesLocal, pointer));
				case Value:
					bytePointers[index] = null;
				case _:
					throw 'Wasm GC C native "${native.name}" has an unsupported argument direction';
			}
		for (index in 0...arguments.length) {
			var pointer = bytePointers[index];
			body.push(LocalGet(pointer == null ? argumentLocals[index] : pointer));
		}
		var resultLocal = native.result == Void ? -1 : allocateLocal(bytePointerResult ? I32 : valueType(native.result));
		body.push(Call(importIndex));
		if (resultLocal >= 0)
			body.push(LocalSet(resultLocal));
		for (index in 0...arguments.length)
			switch native.argumentModes[index] {
				case BytesInputOutput(_) | BytesSize:
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" byte argument $index has no scratch pointer';
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
				case BytesOutput(_):
					var pointer = bytePointers[index];
					if (pointer == null)
						throw 'Wasm GC C native "${native.name}" byte output $index has no scratch pointer';
					body = body.concat([LocalGet(argumentLocals[index]), RefIsNull, If(null), Else]);
					body = body.concat(copyLinearToGcBytes(argumentLocals[index], pointer));
					body.push(End);
				case _:
			}
		if (usesScratchBridge)
			body = body.concat([LocalGet(savedTop), GlobalSet(scratchTop)]);
		if (bytePointerResult)
			body = body.concat(copyNativeBytesResult(native, argumentLocals, resultLocal, outputLocal, pointerLengthImportIndex, pointerReleaseImportIndex));
		else if (resultLocal >= 0)
			body = body.concat([LocalGet(resultLocal), LocalSet(outputLocal)]);
		return body;
	}

	function copyNativeBytesResult(native:IrCNative, argumentLocals:Array<Int>, pointer:Int, outputLocal:Int, lengthImportIndex:Int,
			releaseImportIndex:Int):Array<WasmInstruction> {
		var length = allocateLocal(I32),
			storage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			position = allocateLocal(I32),
			body:Array<WasmInstruction> = [LocalGet(pointer), I32Eqz, If(null)];
		if (native.pointerNullable)
			body = body.concat([RefNull(Type(plan.managedBytesTypeIndex)), LocalSet(outputLocal)]);
		else
			body.push(Unreachable);
		body.push(Else);
		for (argumentLocal in argumentLocals)
			body.push(LocalGet(argumentLocal));
		body = body.concat([
			Call(lengthImportIndex),
			LocalSet(length),
			LocalGet(length),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			End,
			LocalGet(length),
			ArrayNewDefault(plan.byteArrayTypeIndex),
			LocalSet(storage),
			I32Const(0),
			LocalSet(position),
			Block(null),
			Loop(null),
			LocalGet(position),
			LocalGet(length),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(storage),
			LocalGet(position),
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
			End,
			LocalGet(storage),
			I32Const(0),
			LocalGet(length),
			StructNew(plan.managedBytesTypeIndex),
			LocalSet(outputLocal)
		]);
		if (native.pointerOwnership == "owned")
			body = body.concat([LocalGet(pointer), Call(releaseImportIndex)]);
		body.push(End);
		return body;
	}

	function copyGcBytesToLinear(bytesLocal:Int, pointer:Int):Array<WasmInstruction> {
		var position = allocateLocal(I32);
		return [
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
		];
	}

	function copyLinearToGcBytes(bytesLocal:Int, pointer:Int):Array<WasmInstruction> {
		var position = allocateLocal(I32);
		return [
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
		];
	}

	function requireGcBytesLength(bytesLocal:Int, minimum:Int):Array<WasmInstruction>
		return [
			LocalGet(bytesLocal),
			StructGet(plan.managedBytesTypeIndex, 2),
			I32Const(minimum),
			I32LtS,
			If(null),
			Unreachable,
			End
		];

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
				I32Const(1),
				I32ShrU,
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
		return concatStrings(argumentLocals[0], argumentLocals[1], destination);
	}

	function concatStrings(leftLocal:Int, rightLocal:Int, destination:Int):Array<WasmInstruction> {
		var leftLength = allocateLocal(I32),
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

	function stringSplit(sourceLocal:Int, separatorLocal:Int, destination:Int):Array<WasmInstruction> {
		var arrayType = plan.arrayType(Bytes),
			arrayStorage = plan.arrayStorageType(Bytes),
			sourceLength = allocateLocal(I32),
			separatorLength = allocateLocal(I32),
			sourceStorage = allocateLocal(Ref({
				nullable: false,
				heap: Type(plan.byteArrayTypeIndex)
			})),
			separatorStorage = allocateLocal(Ref({nullable: false, heap: Type(plan.byteArrayTypeIndex)})),
			result = allocateLocal(valueType(Array(Bytes))),
			capacity = allocateLocal(I32),
			count = allocateLocal(I32),
			scan = allocateLocal(I32),
			start = allocateLocal(I32),
			separatorIndex = allocateLocal(I32),
			step = allocateLocal(I32),
			firstByte = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(sourceLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(sourceLength),
				LocalGet(separatorLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(separatorLength),
				LocalGet(sourceLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalSet(sourceStorage),
				LocalGet(separatorLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalSet(separatorStorage),
				LocalGet(sourceLength),
				I32Const(1),
				I32Add,
				LocalSet(capacity),
				I32Const(0),
				LocalGet(capacity),
				ArrayNewDefault(arrayStorage),
				StructNew(arrayType),
				LocalSet(result),
				I32Const(0),
				LocalSet(count),
				I32Const(0),
				LocalSet(scan),
				I32Const(0),
				LocalSet(start),
				LocalGet(separatorLength),
				I32Eqz,
				If(null),
				Block(null),
				Loop(null),
				LocalGet(scan),
				LocalGet(sourceLength),
				I32LtS,
				I32Eqz,
				BrIf(1),
				LocalGet(sourceStorage),
				LocalGet(sourceLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(scan),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				LocalTee(firstByte),
				I32Const(240),
				I32LtS,
				I32Eqz,
				If(I32),
				I32Const(4),
				Else,
				LocalGet(firstByte),
				I32Const(224),
				I32LtS,
				I32Eqz,
				If(I32),
				I32Const(3),
				Else,
				LocalGet(firstByte),
				I32Const(192),
				I32LtS,
				I32Eqz,
				If(I32),
				I32Const(2),
				Else,
				I32Const(1),
				End,
				End,
				End,
				LocalSet(step),
				LocalGet(scan),
				LocalSet(start),
				LocalGet(scan),
				LocalGet(step),
				I32Add,
				LocalSet(scan)
			];
		appendSplitPart(body, plan, arrayType, arrayStorage, sourceLocal, result, count, start, scan);
		body = body.concat([Br(0), End, End, Else, I32Const(0), LocalSet(scan), Block(null), Loop(null)]);
		body = body.concat([
			LocalGet(scan),
			LocalGet(separatorLength),
			I32Add,
			LocalGet(sourceLength),
			I32LeS,
			I32Eqz,
			BrIf(1),
			I32Const(0),
			LocalSet(separatorIndex),
			Block(null),
			Loop(null),
			LocalGet(separatorIndex),
			LocalGet(separatorLength),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(sourceStorage),
			LocalGet(sourceLocal),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(scan),
			I32Add,
			LocalGet(separatorIndex),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			LocalGet(separatorStorage),
			LocalGet(separatorLocal),
			StructGet(plan.bytesTypeIndex, 1),
			LocalGet(separatorIndex),
			I32Add,
			ArrayGetUnsigned(plan.byteArrayTypeIndex),
			I32Eq,
			I32Eqz,
			BrIf(1),
			LocalGet(separatorIndex),
			I32Const(1),
			I32Add,
			LocalSet(separatorIndex),
			Br(0),
			End,
			End,
			LocalGet(separatorIndex),
			LocalGet(separatorLength),
			I32Eq,
			If(null)
		]);
		appendSplitPart(body, plan, arrayType, arrayStorage, sourceLocal, result, count, start, scan);
		body = body.concat([
			LocalGet(scan),
			LocalGet(separatorLength),
			I32Add,
			LocalSet(scan),
			LocalGet(scan),
			LocalSet(start),
			Else,
			LocalGet(scan),
			I32Const(1),
			I32Add,
			LocalSet(scan),
			End,
			Br(0),
			End,
			End
		]);
		appendSplitPart(body, plan, arrayType, arrayStorage, sourceLocal, result, count, start, sourceLength);
		body.push(End);
		body = body.concat([LocalGet(result), LocalSet(destination)]);
		return body;
	}

	static function appendSplitPart(body:Array<WasmInstruction>, plan:WasmGcTypePlan, arrayType:Int, arrayStorage:Int, sourceLocal:Int, resultLocal:Int,
			countLocal:Int, startLocal:Int, endLocal:Int):Void {
		body.push(LocalGet(resultLocal));
		body.push(StructGet(arrayType, WasmGcTypePlan.arrayDataFieldIndex()));
		body.push(LocalGet(countLocal));
		body.push(LocalGet(sourceLocal));
		body.push(StructGet(plan.bytesTypeIndex, 0));
		body.push(LocalGet(sourceLocal));
		body.push(StructGet(plan.bytesTypeIndex, 1));
		body.push(LocalGet(startLocal));
		body.push(I32Add);
		body.push(LocalGet(endLocal));
		body.push(LocalGet(startLocal));
		body.push(I32Sub);
		body.push(StructNew(plan.bytesTypeIndex));
		body.push(ArraySet(arrayStorage));
		body.push(LocalGet(resultLocal));
		body.push(LocalGet(countLocal));
		body.push(I32Const(1));
		body.push(I32Add);
		body.push(StructSet(arrayType, WasmGcTypePlan.arrayLengthFieldIndex()));
		body.push(LocalGet(countLocal));
		body.push(I32Const(1));
		body.push(I32Add);
		body.push(LocalSet(countLocal));
	}

	function arrayJoinBytes(arrayLocal:Int, separatorLocal:Int, destination:Int):Array<WasmInstruction> {
		var wrapperType = plan.arrayType(Bytes),
			storageType = plan.arrayStorageType(Bytes),
			length = allocateLocal(I32),
			index = allocateLocal(I32),
			empty = allocateLocal(Ref({
				nullable: false,
				heap: Type(plan.bytesTypeIndex)
			})),
			accumulator = allocateLocal(Ref({nullable: false, heap: Type(plan.bytesTypeIndex)})),
			separator = allocateLocal(valueType(Bytes)),
			element = allocateLocal(valueType(Bytes)),
			body:Array<WasmInstruction> = [
				I32Const(0),
				ArrayNewDefault(plan.byteArrayTypeIndex),
				I32Const(0),
				I32Const(0),
				StructNew(plan.bytesTypeIndex),
				LocalSet(empty),
				LocalGet(empty),
				LocalSet(accumulator),
				LocalGet(separatorLocal),
				LocalSet(separator),
				LocalGet(separator),
				RefIsNull,
				If(null),
				LocalGet(empty),
				LocalSet(separator),
				End,
				LocalGet(arrayLocal),
				StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
				LocalSet(length),
				I32Const(0),
				LocalSet(index),
				Loop(null),
				LocalGet(index),
				LocalGet(length),
				I32LtS,
				If(null),
				LocalGet(index),
				I32Eqz,
				If(null),
				Else
			];
		body = body.concat(concatStrings(accumulator, separator, accumulator));
		body = body.concat([
			End,
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayDataFieldIndex()),
			LocalGet(index),
			ArrayGet(storageType),
			LocalSet(element),
			LocalGet(element),
			RefIsNull,
			If(null),
			LocalGet(empty),
			LocalSet(element),
			End
		]);
		body = body.concat(concatStrings(accumulator, element, accumulator));
		body = body.concat([
			LocalGet(index),
			I32Const(1),
			I32Add,
			LocalSet(index),
			Br(1),
			End,
			End,
			LocalGet(accumulator),
			LocalSet(destination)
		]);
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

	function stringCompare(leftLocal:Int, rightLocal:Int, destination:Int):Array<WasmInstruction> {
		var leftLength = allocateLocal(I32),
			rightLength = allocateLocal(I32),
			commonLength = allocateLocal(I32),
			index = allocateLocal(I32),
			leftByte = allocateLocal(I32),
			rightByte = allocateLocal(I32),
			result = allocateLocal(I32),
			body:Array<WasmInstruction> = [
				LocalGet(leftLocal),
				RefIsNull,
				If(null),
				LocalGet(rightLocal),
				RefIsNull,
				If(null),
				I32Const(0),
				LocalSet(destination),
				Else,
				I32Const(-1),
				LocalSet(destination),
				End,
				Else,
				LocalGet(rightLocal),
				RefIsNull,
				If(null),
				I32Const(1),
				LocalSet(destination),
				Else,
				LocalGet(leftLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(leftLength),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 2),
				LocalSet(rightLength),
				LocalGet(leftLength),
				LocalGet(rightLength),
				I32LtS,
				If(I32),
				LocalGet(leftLength),
				Else,
				LocalGet(rightLength),
				End,
				LocalSet(commonLength),
				I32Const(0),
				LocalSet(index),
				I32Const(0),
				LocalSet(result),
				Block(null),
				Loop(null),
				LocalGet(index),
				LocalGet(commonLength),
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
				LocalSet(leftByte),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 0),
				LocalGet(rightLocal),
				StructGet(plan.bytesTypeIndex, 1),
				LocalGet(index),
				I32Add,
				ArrayGetUnsigned(plan.byteArrayTypeIndex),
				LocalSet(rightByte),
				LocalGet(leftByte),
				LocalGet(rightByte),
				I32LtS,
				If(null),
				I32Const(-1),
				LocalSet(result),
				Br(2),
				End,
				LocalGet(rightByte),
				LocalGet(leftByte),
				I32LtS,
				If(null),
				I32Const(1),
				LocalSet(result),
				Br(2),
				End,
				LocalGet(index),
				I32Const(1),
				I32Add,
				LocalSet(index),
				Br(0),
				End,
				End,
				LocalGet(result),
				I32Eqz,
				If(null),
				LocalGet(leftLength),
				LocalGet(rightLength),
				I32LtS,
				If(I32),
				I32Const(-1),
				Else,
				LocalGet(rightLength),
				LocalGet(leftLength),
				I32LtS,
				If(I32),
				I32Const(1),
				Else,
				I32Const(0),
				End,
				End,
				LocalSet(result),
				End,
				LocalGet(result),
				LocalSet(destination),
				End,
				End
			];
		return body;
	}

	static function requireInstructions(instructions:Null<Array<WasmInstruction>>):Array<WasmInstruction>
		return if (instructions == null) throw "Wasm GC array operation was not lowered" else instructions;

	static function isNamedAbstract(type:IrType, name:String):Bool
		return switch type {
			case Abstract(abstractName): abstractName == name;
			default: false;
		};

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
