package compiler.backend.c;

import compiler.core.InternalError;
import compiler.hl.HlCode;
import compiler.hl.HlType;

/** A field of an object type as C sees it: flattened from the base down, so `index` is HashLink's field index. */
typedef HlcField = {
	final index:Int;
	final name:String;
	final type:Int;
}

/**
 * The C view of a HashLink module's type table (docs/design/AOT_BACKEND.md): a C type per HashLink type, a struct per object
 * type laid out as `hl_get_obj_rt` lays it out, and the offsets `hl_module_alloc` gives globals. Nothing here decides a
 * layout: the type table the HashLink assembly made does, and the generated image checks these offsets against the
 * runtime's at startup.
 */
class HlcTypes {
	final code:HlCode;
	final fieldCache:Map<Int, Array<HlcField>> = [];

	public function new(code:HlCode)
		this.code = code;

	public function kind(index:Int):HlType
		return switch code.types[index] {
			case Simple(kind): kind;
			case EnumTag(_, _): HlType.EnumTag;
			case Parameterized(kind, _): kind;
			case Abstract(_): HlType.Abstract;
			case Function(_, _): HlType.Fun;
			case Method(_, _): HlType.Method;
			case Object(_, _, _, _, _, _): HlType.Obj;
			case Structure(_, _, _, _, _): HlType.Struct;
			case Virtual(_, _): HlType.Virtual;
			case Enum(_, _, _): HlType.Enum;
		};

	/** The type `Null<T>`, `Ref<T>` or `Packed<T>` wraps. */
	public function parameter(index:Int):Int
		return switch code.types[index] {
			case Parameterized(_, parameter): parameter;
			default: throw new InternalError('HashLink type $index has no parameter');
		};

	/** The C type a value of type `index` is held in. */
	public function cType(index:Int):String
		return switch code.types[index] {
			case Object(_, _, _, _, _, _), Structure(_, _, _, _, _): structName(index) + "*";
			case Parameterized(Ref, parameter): cType(parameter) + "*";
			case Parameterized(Packed, parameter): "struct " + structName(parameter);
			default: kindType(kind(index));
		};

	public static function kindType(kind:HlType):String
		return switch kind {
			case Void: "void";
			case Ui8: "unsigned char";
			case Ui16: "unsigned short";
			case I32, EnumTag: "int";
			case I64, Guid: "int64";
			case F32: "float";
			case F64: "double";
			case Bool: "bool";
			case Bytes: "vbyte*";
			case Dyn, Null: "vdynamic*";
			case Fun: "vclosure*";
			case Array: "varray*";
			case Type: "hl_type*";
			case Virtual: "vvirtual*";
			case DynObj: "vdynobj*";
			case Enum: "venum*";
			case Abstract, Method, Ref: "void*";
			case Obj, Struct, Packed: throw new InternalError('HashLink kind $kind has no C type of its own');
		};

	/** Whether a value of type `index` is a pointer the collector follows. */
	public function isPointer(index:Int):Bool
		return switch kind(index) {
			case Void, Ui8, Ui16, I32, I64, F32, F64, Bool, Guid, EnumTag, Packed: false;
			default: true;
		};

	public function isVoid(index:Int):Bool
		return kind(index) == Void;

	/** `hl_type_size`: the bytes a value of type `index` takes in a global, a field or an array. */
	public function size(index:Int):Int
		return switch kind(index) {
			case Void, Packed: 0;
			case Ui8, Bool: 1;
			case Ui16: 2;
			case I32, F32, EnumTag: 4;
			case I64, F64, Guid: 8;
			default: 8;
		};

	/** The struct of object type `index`. */
	public function structName(index:Int):String
		return "hlc_obj" + index;

	/** The object type a struct type's base is, or -1. */
	public function base(index:Int):Int
		return switch code.types[index] {
			case Object(_, base, _, _, _, _): base;
			default: -1;
		};

	public function typeName(index:Int):String
		return switch code.types[index] {
			case Object(name, _, _, _, _, _), Structure(name, _, _, _, _), Virtual(name, _), Enum(name, _, _),
				Abstract(name): code.strings[name];
			default: Std.string(kind(index));
		};

	/** Every field of object type `index`, its bases' first. */
	public function fields(index:Int):Array<HlcField> {
		var cached = fieldCache.get(index);
		if (cached != null)
			return cached;
		var result:Array<HlcField> = [];
		switch code.types[index] {
			case Object(_, base, _, own, _, _):
				if (base >= 0)
					result = fields(base).copy();
				for (field in own)
					result.push({index: result.length, name: code.strings[field.name], type: field.type});
			case Structure(_, _, own, _, _):
				for (field in own)
					result.push({index: result.length, name: code.strings[field.name], type: field.type});
			default:
				throw new InternalError('HashLink type $index is not an object');
		}
		fieldCache.set(index, result);
		return result;
	}

	/** The function type of a method of object type `index` named `name`, in it or a base, or -1 when it has none. */
	public function methodFunction(index:Int, name:String):Int {
		var current = index;
		while (current >= 0) {
			switch code.types[current] {
				case Object(_, base, _, _, methods, _):
					for (method in methods)
						if (code.strings[method.name] == name)
							return method.functionIndex;
					current = base;
				default:
					return -1;
			}
		}
		return -1;
	}

	/**
	 * The struct definitions of object types `indices` (each a struct type), an inline (packed) field's struct before the struct
	 * that holds it, which is then defined too. Fields are flattened from the base down: `hl_get_obj_rt` starts a subclass's
	 * fields right after its base's last one, with none of the tail padding a nested base struct would add. The structs the
	 * fields point to need only their typedefs.
	 */
	public function structDefinitions(indices:Array<Int>, buffer:StringBuf):Void {
		var written:Map<Int, Bool> = [];
		function write(index:Int):Void {
			if (written.exists(index))
				return;
			written.set(index, true);
			for (field in fields(index))
				if (kind(field.type) == Packed)
					write(parameter(field.type));
			buffer.add('struct ${structName(index)} { /* ${typeName(index)} */\n');
			if (kind(index) == Obj)
				buffer.add("\thl_type *t;\n");
			for (field in fields(index))
				if (!isVoid(field.type))
					buffer.add('\t${cType(field.type)} f${field.index}; /* ${field.name} */\n');
			buffer.add("};\n");
		}
		for (index in indices)
			write(index);
	}

	public function isObject(index:Int):Bool
		return switch code.types[index] {
			case Object(_, _, _, _, _, _), Structure(_, _, _, _, _): true;
			default: false;
		};

	/** The byte offset of each global in the module's global data, by `hl_module_alloc`'s rule: each aligned to its own size. */
	public function globalOffsets():Array<Int> {
		var offsets:Array<Int> = [], position = 0;
		for (global in code.globals) {
			var size = size(global);
			if (size > 0)
				position += (-position) & (size - 1);
			offsets.push(position);
			position += size;
		}
		return offsets;
	}

	/** Field `slot` of virtual type `index`: its name and type. */
	public function virtualField(index:Int, slot:Int):{name:String, type:Int} return switch code.types[index] {
		case Virtual(_, fields): {name: code.strings[fields[slot].name], type: fields[slot].type};
		default: throw new InternalError('HashLink type $index is not a virtual');
	};

	/** The slot of field `name` in virtual type `index`, or -1. */
	public function virtualSlot(index:Int, name:String):Int
		return switch code.types[index] {
			case Virtual(_, fields):
				var found = -1;
				for (slot in 0...fields.length)
					if (code.strings[fields[slot].name] == name)
						found = slot;
				found;
			default: -1;
		};

	/** The argument and result types of function type `index`. */
	public function signature(index:Int):{arguments:Array<Int>, result:Int} return switch code.types[index] {
		case Function(arguments, result), Method(arguments, result): {arguments: arguments, result: result};
		default: throw new InternalError('HashLink type $index is not a function type');
	};
}
