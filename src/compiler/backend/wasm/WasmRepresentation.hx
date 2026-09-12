package compiler.backend.wasm;

import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Operations whose representation differs between linear pointers and Wasm references. */
interface WasmRepresentation {
	public function valueType(type:IrType):WasmValueType;
	public function zeroValue(type:IrType):Array<WasmInstruction>;
	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>;
	public function newObject(typeName:String, destination:Int):Array<WasmInstruction>;
	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction>;
	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction>;
	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction>;
	public function beginFunction(allocateLocal:WasmValueType->Int):Void;
	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
		argumentLocals:Array<Int>):Null<Array<WasmInstruction>>;
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

	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		var instruction = switch left.type {
			case I64: I64Eq;
			case F64: F64Eq;
			default: I32Eq;
		};
		return [LocalGet(leftLocal), LocalGet(rightLocal), instruction, LocalSet(output)];
	}

	public function beginFunction(allocateLocal:WasmValueType->Int):Void {}

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>>
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
	var requiredArrayLengthLocal:Null<Int>;
	var arrayCapacityLocal:Null<Int>;

	public function new(plan:WasmGcTypePlan)
		this.plan = plan;

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
				throw 'Wasm GC equality for ${Std.string(left.type)} is not supported yet';
			case Void:
				throw "Wasm GC cannot compare void values";
		};
	}

	public function beginFunction(allocateLocal:WasmValueType->Int):Void {
		this.allocateLocal = allocateLocal;
		arrayReferenceLocals.clear();
		requiredArrayLengthLocal = null;
		arrayCapacityLocal = null;
	}

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int,
			argumentLocals:Array<Int>):Null<Array<WasmInstruction>> {
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
		var body:Array<WasmInstruction> = [
			LocalGet(indexLocal),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			End,
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
		];
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
			Else,
			Unreachable,
			End
		];
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

	static function checkedIndex(indexLocal:Int, arrayLocal:Int, wrapperType:Int):Array<WasmInstruction>
		return [
			LocalGet(indexLocal),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			End,
			LocalGet(indexLocal),
			LocalGet(arrayLocal),
			StructGet(wrapperType, WasmGcTypePlan.arrayLengthFieldIndex()),
			I32LtS,
			I32Eqz,
			If(null),
			Unreachable,
			End
		];

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
