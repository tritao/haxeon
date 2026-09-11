package compiler.backend.wasm;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

typedef WasmFieldLayout = {
	final name:String;
	final offset:Int;
	final type:IrType;
}

typedef WasmObjectLayout = {
	final name:String;
	final size:Int;
	final fields:Array<WasmFieldLayout>;
}

typedef WasmEnumLayout = {
	final name:String;
	final size:Int;
	final cases:Array<Array<IrType>>;
}

/** One authoritative linear-memory layout for all managed Haxeon values. */
class WasmLayout {
	public final program:IrProgram;

	public static inline final HEADER_SIZE = 8;
	public static inline final ARRAY_LENGTH_OFFSET = 8;
	public static inline final ARRAY_CAPACITY_OFFSET = 12;
	public static inline final ARRAY_DATA_POINTER_OFFSET = 16;
	public static inline final ARRAY_HEADER_SIZE = 24;
	public static inline final DYN_PAYLOAD_OFFSET = 4;
	public static inline final DYN_I32_SIZE = 8;
	public static inline final DYN_F64_SIZE = 16;
	public static inline final MAP_COUNT_OFFSET = 8;
	public static inline final MAP_CAPACITY_OFFSET = 12;
	public static inline final MAP_ENTRIES_OFFSET = 16;
	public static inline final MAP_HEADER_SIZE = 24;

	public final objects:Map<String, WasmObjectLayout> = [];
	public final enums:Map<String, WasmEnumLayout> = [];

	public function new(program:IrProgram) {
		this.program = program;
		for (object in program.objects)
			buildObjectLayout(object, []);
		for (enumDecl in program.enums)
			enums.set(enumDecl.name, enumLayout(enumDecl));
	}

	public function object(name:String):WasmObjectLayout {
		if (!objects.exists(name))
			throw 'Unknown Wasm object layout "$name"';
		return objects.get(name);
	}

	public function field(objectName:String, fieldName:String):WasmFieldLayout {
		for (field in object(objectName).fields)
			if (field.name == fieldName)
				return field;
		throw 'Unknown field "$objectName.$fieldName" in Wasm layout';
	}

	public function enumType(name:String):WasmEnumLayout {
		if (!enums.exists(name))
			throw 'Unknown Wasm enum layout "$name"';
		return enums.get(name);
	}

	public static function enumLayout(enumDecl:IrEnum):WasmEnumLayout {
		var maxPayload = 0;
		for (constructor in enumDecl.cases) {
			var offset = HEADER_SIZE + 4;
			for (type in constructor.params)
				offset = align(offset, alignmentOf(type)) + sizeOf(type);
			var payload = offset - (HEADER_SIZE + 4);
			if (payload > maxPayload)
				maxPayload = payload;
		}
		return {name: enumDecl.name, size: align(HEADER_SIZE + 4 + maxPayload, 8), cases: [for (constructor in enumDecl.cases) constructor.params]};
	}

	function buildObjectLayout(object:IrObject, visiting:Array<String>):WasmObjectLayout {
		if (objects.exists(object.name))
			return objects.get(object.name);
		if (visiting.indexOf(object.name) >= 0)
			throw 'Cyclic Wasm object inheritance at "${object.name}"';
		var nextVisiting = visiting.copy();
		nextVisiting.push(object.name);
		var offset = HEADER_SIZE, fields:Array<WasmFieldLayout> = [];
		if (object.base != null) {
			var baseDecl:Null<IrObject> = null;
			for (candidate in program.objects)
				if (candidate.name == object.base)
					baseDecl = candidate;
			if (baseDecl == null)
				throw 'Unknown Wasm base object "${object.base}" for "${object.name}"';
			var base = buildObjectLayout(baseDecl, nextVisiting);
			fields = base.fields.copy();
			offset = base.size;
		}
		for (field in object.fields) {
			offset = align(offset, alignmentOf(field.type));
			fields.push({name: field.name, offset: offset, type: field.type});
			offset += sizeOf(field.type);
		}
		var result:WasmObjectLayout = {name: object.name, size: align(offset, 8), fields: fields};
		objects.set(object.name, result);
		return result;
	}

	public function enumField(typeName:String, constructor:Int, field:Int):{type:IrType, offset:Int} {
		var layout = enumType(typeName);
		if (constructor < 0 || constructor >= layout.cases.length)
			throw 'Unknown constructor $constructor in Wasm enum layout "$typeName"';
		var params = layout.cases[constructor];
		if (field < 0 || field >= params.length)
			throw 'Unknown field $field in Wasm enum constructor $constructor of "$typeName"';
		var offset = HEADER_SIZE + 4;
		for (index in 0...field)
			offset = align(offset, alignmentOf(params[index])) + sizeOf(params[index]);
		offset = align(offset, alignmentOf(params[field]));
		return {type: params[field], offset: offset};
	}

	public static function sizeOf(type:IrType):Int
		return switch type {
			case F64: 8;
			case Void: 0;
			default: 4;
		};

	public static function arrayStride(type:IrType):Int
		return type == F64 ? 8 : 4;

	public static function arrayAllocationSize(type:IrType, length:Int):Int
		return ARRAY_HEADER_SIZE + arrayStride(type) * length;

	public static inline final STRING_LENGTH_OFFSET = 8;
	public static inline final STRING_DATA_OFFSET = 16;
	public static inline final CLOSURE_FUNCTION_OFFSET = 8;
	public static inline final CLOSURE_RECEIVER_OFFSET = 12;
	public static inline final CLOSURE_SIZE = 16;

	public static function alignmentOf(type:IrType):Int
		return type == F64 ? 8 : 4;

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);
}
