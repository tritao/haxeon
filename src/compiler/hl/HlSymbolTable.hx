package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlCode.HlVirtualField;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;

typedef HlNamedIndex = {final name:String; final index:Int;}
typedef HlNamedSlots = {final name:String; final slots:Array<HlNamedIndex>;}

typedef HlSymbolState = {
	final ints:Array<Int>;
	final strings:Array<String>;
	final floats:Array<Float>;
	final types:Array<HlTypeDef>;
	final globals:Array<Int>;
	final typeIndices:Array<HlNamedIndex>;
	final globalIndices:Array<HlNamedIndex>;
	final objectIndices:Array<HlNamedIndex>;
	final objectMethodIndices:Array<HlNamedSlots>;
	final interfaceMethodIndices:Array<HlNamedSlots>;
}

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
	final globalIndices:Map<String, Int> = [];
	final objectIndices:Map<String, Int> = [];
	final objectMethodIndices:Map<String, Map<String, Int>> = [];
	final interfaceMethodIndices:Map<String, Map<String, Int>> = [];

	public function new() {}

	public function copy():HlSymbolTable {
		var result = new HlSymbolTable();
		for (value in ints)
			result.internInt(value);
		for (value in strings)
			result.internString(value);
		for (value in floats)
			result.internFloat(value);
		for (index in 0...types.length)
			result.types.push(types[index]);
		for (index in 0...globals.length)
			result.globals.push(globals[index]);
		copyMap(typeIndices, result.typeIndices);
		copyMap(globalIndices, result.globalIndices);
		copyMap(objectIndices, result.objectIndices);
		copyNestedMap(objectMethodIndices, result.objectMethodIndices);
		copyNestedMap(interfaceMethodIndices, result.interfaceMethodIndices);
		return result;
	}

	public function exportState():HlSymbolState
		return {
			ints: ints.copy(),
			strings: strings.copy(),
			floats: floats.copy(),
			types: types.copy(),
			globals: globals.copy(),
			typeIndices: orderedMap(typeIndices),
			globalIndices: orderedMap(globalIndices),
			objectIndices: orderedMap(objectIndices),
			objectMethodIndices: orderedNestedMap(objectMethodIndices),
			interfaceMethodIndices: orderedNestedMap(interfaceMethodIndices)
		};

	public static function fromState(state:HlSymbolState):HlSymbolTable {
		var result = new HlSymbolTable();
		for (value in state.ints)
			result.ints.push(value);
		for (index in 0...state.ints.length)
			if (result.intIndices.exists(state.ints[index]))
				throw "Duplicate persisted integer symbol";
			else
				result.intIndices.set(state.ints[index], index);
		for (value in state.strings)
			result.strings.push(value);
		for (index in 0...state.strings.length)
			if (result.stringIndices.exists(state.strings[index]))
				throw "Duplicate persisted string symbol";
			else
				result.stringIndices.set(state.strings[index], index);
		for (value in state.floats)
			result.floats.push(value);
		for (index in 0...state.floats.length) {
			var key = Std.string(state.floats[index]);
			if (result.floatIndices.exists(key))
				throw "Duplicate persisted float symbol";
			else
				result.floatIndices.set(key, index);
		}
		for (type in state.types)
			result.types.push(type);
		for (global in state.globals)
			result.globals.push(global);
		loadMap(state.typeIndices, result.typeIndices, "type");
		loadMap(state.globalIndices, result.globalIndices, "global");
		loadMap(state.objectIndices, result.objectIndices, "object");
		loadNestedMap(state.objectMethodIndices, result.objectMethodIndices, "object method");
		loadNestedMap(state.interfaceMethodIndices, result.interfaceMethodIndices, "interface method");
		return result;
	}

	static function orderedMap(values:Map<String, Int>):Array<HlNamedIndex> {
		var result = [for (name => index in values) {name: name, index: index}];
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return result;
	}

	static function orderedNestedMap(values:Map<String, Map<String, Int>>):Array<HlNamedSlots> {
		var result = [for (name => slots in values) {name: name, slots: orderedMap(slots)}];
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return result;
	}

	static function loadMap(entries:Array<HlNamedIndex>, target:Map<String, Int>, kind:String):Void
		for (entry in entries) {
			if (entry.name.length == 0 || entry.index < 0 || target.exists(entry.name))
				throw 'Invalid persisted $kind index';
			target.set(entry.name, entry.index);
		}

	static function loadNestedMap(entries:Array<HlNamedSlots>, target:Map<String, Map<String, Int>>, kind:String):Void
		for (entry in entries) {
			if (entry.name.length == 0 || target.exists(entry.name))
				throw 'Invalid persisted $kind owner';
			var slots:Map<String, Int> = [];
			loadMap(entry.slots, slots, kind);
			target.set(entry.name, slots);
		}

	static function copyMap(source:Map<String, Int>, target:Map<String, Int>):Void
		for (key => value in source)
			target.set(key, value);

	static function copyNestedMap(source:Map<String, Map<String, Int>>, target:Map<String, Map<String, Int>>):Void
		for (name => values in source) {
			var copied:Map<String, Int> = [];
			copyMap(values, copied);
			target.set(name, copied);
		}

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
			case Enum(name):
				throw 'Enum type "$name" must be registered before use';
			case Virtual(name):
				throw 'Virtual type "$name" must be registered before use';
			default:
		}
		var index = types.length;
		if (typeKey(type).indexOf("obj:") == 0)
			throw 'Object type "$type" must be registered before use';
		types.push(switch type {
			case Abstract(name): HlTypeDef.Abstract(internString(name));
			default: HlTypeDef.Simple(switch type {
					case Void: HlType.Void;
					case I32: HlType.I32;
					case Bool: HlType.Bool;
					case F64: HlType.F64;
					case Bytes: HlType.Bytes;
					case Dyn: HlType.Dyn;
					case TypeRef: HlType.Type;
					case Array(_): HlType.Array;
					case Obj(name): throw 'Object type "$name" must be registered before use';
					case Abstract(name): throw 'Abstract type "$name" must be handled by the outer type switch';
					case Virtual(name): throw 'Virtual type "$name" must be registered before use';
					case Function(_, _): throw 'Function type must be interned with internFunction';
					case Enum(name): throw 'Enum type "$name" must be registered before use';
				});
		});
		typeIndices.set(key, index);
		return index;
	}

	public function internEnum(enumDecl:IrEnum):Int {
		var key = 'enum:${enumDecl.name}', found = typeIndices.get(key);
		if (found != null)
			return found;
		var constructors = [
			for (constructor in enumDecl.cases)
				{name: internString(constructor.name), params: [for (param in constructor.params) internType(param)]}
		];
		var index = types.length;
		types.push(Enum(internString(enumDecl.name), 0, constructors));
		typeIndices.set(key, index);
		return index;
	}

	public function internInterface(interfaceDecl:IrInterface):Int {
		var name = interfaceDecl.name,
			key = 'virt:$name',
			found = typeIndices.get(key);
		if (found != null)
			return found;
		var fields:Array<Null<HlVirtualField>> = [], slots:Map<String, Int> = [], next = 0;
		for (base in interfaceDecl.bases) {
			var inherited = interfaceMethodIndices.get(base);
			if (inherited != null)
				for (methodName => slot in inherited) {
					slots.set(methodName, slot);
					if (slot >= next)
						next = slot + 1;
					var baseIndex = typeIndices.get('virt:$base');
					if (baseIndex != null)
						switch types[baseIndex] {
							case Virtual(baseFields):
								if (slot < baseFields.length)
									fields[slot] = baseFields[slot];
							default:
						}
				}
		}
		for (method in interfaceDecl.methods) {
			var slot = slots.get(method.name);
			if (slot == null) {
				slot = next++;
				slots.set(method.name, slot);
			}
			var type = internFunction(method.arguments, method.result);
			fields[slot] = {name: internString(method.name), type: type};
		}
		for (field in fields)
			if (field == null)
				throw 'Interface "$name" has an unassigned virtual slot';
		var index = types.length;
		types.push(Virtual([for (field in fields) field]));
		typeIndices.set(key, index);
		interfaceMethodIndices.set(name, slots);
		return index;
	}

	public function internObject(object:IrObject, functionIndices:Map<String, Int>):Int {
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
		var slots:Map<String, Int> = [], nextSlot = 0;
		if (object.base != null) {
			var inherited = objectMethodIndices.get(object.base);
			if (inherited != null)
				for (name => slot in inherited) {
					slots.set(name, slot);
					if (slot >= nextSlot)
						nextSlot = slot + 1;
				}
		}
		var methods = [];
		for (method in object.methods) {
			var slot = slots.get(method.name);
			if (slot == null) {
				slot = nextSlot++;
				slots.set(method.name, slot);
			}
			var functionIndex = functionIndices.get(method.functionName);
			if (functionIndex == null)
				throw 'Unknown object method function "${method.functionName}"';
			methods.push({name: internString(method.name), functionIndex: functionIndex, prototype: slot});
		}
		types.push(Object(internString(object.name), base == null ? -1 : base, global, fields, methods, []));
		objectIndices.set(object.name, index);
		typeIndices.set('obj:${object.name}', index);
		objectMethodIndices.set(object.name, slots);
		globals.push(index);
		return index;
	}

	public function typeIndex(key:String):Null<Int>
		return typeIndices.get(key);

	public function internGlobal(name:String, type:IrType):Int {
		var found = globalIndices.get(name);
		if (found != null)
			return found;
		var index = globals.length;
		globals.push(internType(type));
		globalIndices.set(name, index);
		return index;
	}

	public function globalIndex(name:String):Null<Int>
		return globalIndices.get(name);

	public function objectMethodIndex(objectName:String, methodName:String):Null<Int> {
		var methods = objectMethodIndices.get(objectName);
		return methods == null ? null : methods.get(methodName);
	}

	public function interfaceMethodIndex(interfaceName:String, methodName:String):Null<Int> {
		var methods = interfaceMethodIndices.get(interfaceName);
		return methods == null ? null : methods.get(methodName);
	}

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
			case Dyn: "dyn";
			case TypeRef: "type";
			case Array(element): 'array:${typeKey(element)}';
			case Obj(name): 'obj:$name';
			case Abstract(name): 'abstract:$name';
			case Enum(name): 'enum:$name';
			case Virtual(name): 'virt:$name';
			case Function(arguments, result): 'fun(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
		};
}
