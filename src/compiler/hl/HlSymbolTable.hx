package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrObject;

class HlSymbolTable {
	public final ints:Array<Int> = [];
	public final strings:Array<String> = [];
	public final floats:Array<Float> = [];
	public final types:Array<HlTypeDef> = [];
	public final globals:Array<Int> = [];

	final intIndices:Map<Int, Int> = [];
	final stringIndices:Map<String, Int> = [];
	final floatIndices:Map<String, Int> = [];
	final typeIndices:Map<String, Int> = [];
	final objectIndices:Map<String, Int> = [];

	public function new() {}

	public function internInt(value:Int):Int {
		var found = intIndices.get(value);
		if (found != null)
			return found;
		var index = ints.length;
		ints.push(value);
		intIndices.set(value, index);
		return index;
	}

	public function internString(value:String):Int {
		var found = stringIndices.get(value);
		if (found != null)
			return found;
		var index = strings.length;
		strings.push(value);
		stringIndices.set(value, index);
		return index;
	}

	public function internFloat(value:Float):Int {
		var key = Std.string(value), found = floatIndices.get(key);
		if (found != null)
			return found;
		var index = floats.length;
		floats.push(value);
		floatIndices.set(key, index);
		return index;
	}

	public function internType(type:IrType):Int {
		var key = typeKey(type), found = typeIndices.get(key);
		if (found != null)
			return found;
		switch type {
			case Function(arguments, result):
				return internFunction(arguments, result);
			default:
		}
		var index = types.length;
		if (typeKey(type).indexOf("obj:") == 0)
			throw 'Object type "$type" must be registered before use';
		types.push(Simple(switch type {
			case Void: HlType.Void;
			case I32: HlType.I32;
			case Bool: HlType.Bool;
			case F64: HlType.F64;
			case Bytes: HlType.Bytes;
			case Obj(name): throw 'Object type "$name" must be registered before use';
			case Function(_, _): throw 'Function type must be interned with internFunction';
		}));
		typeIndices.set(key, index);
		return index;
	}

	public function internObject(object:IrObject):Int {
		var found = objectIndices.get(object.name);
		if (found != null)
			return found;
		var fields = [
			for (field in object.fields)
				{name: internString(field.name), type: internType(field.type)}
		], index = types.length, global = globals.length + 1;
		var base = object.base == null ? -1 : typeIndices.get('obj:${object.base}');
		if (object.base != null && base == null)
			throw 'Object base "${object.base}" must be registered before "${object.name}"';
		types.push(Object(internString(object.name), base == null ? -1 : base, global, fields, [], []));
		objectIndices.set(object.name, index);
		typeIndices.set('obj:${object.name}', index);
		globals.push(index);
		return index;
	}

	public function typeIndex(key:String):Null<Int>
		return typeIndices.get(key);

	public function internFunction(arguments:Array<IrType>, result:IrType):Int {
		var key = 'fun(${[for (a in arguments) typeKey(a)].join(",")})->${typeKey(result)}',
			found = typeIndices.get(key);
		if (found != null)
			return found;
		var args = [for (a in arguments) internType(a)],
			ret = internType(result),
			index = types.length;
		types.push(Function(args, ret));
		typeIndices.set(key, index);
		return index;
	}

	static function typeKey(type:IrType):String
		return switch type {
			case Void: "void";
			case I32: "i32";
			case Bool: "bool";
			case F64: "f64";
			case Bytes: "bytes";
			case Obj(name): 'obj:$name';
			case Function(arguments, result): 'fun(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
		};
}
