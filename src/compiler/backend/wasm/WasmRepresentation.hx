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

	static function requireObjectName(type:IrType):String
		return switch type {
			case Obj(name): name;
			default: throw 'Wasm GC field access requires an object reference, got ${Std.string(type)}';
		};
}
