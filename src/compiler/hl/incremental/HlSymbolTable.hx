package compiler.hl.incremental;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlCode.HlVirtualField;
import compiler.hl.HlCode.HlObjectMethod;
import compiler.hl.HlType;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;

/** Persisted association between a semantic name and an append-only index. */
typedef HlNamedIndex = {final name:String; final index:Int;}

/** Persisted ordered member indices owned by one named type. */
typedef HlNamedSlots = {final name:String; final slots:Array<HlNamedIndex>;}

/** Complete persistable state of the HashLink symbol tables. */
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

/**
 * Interns constants, types, globals, and dispatch slots into stable arrays.
 * Published prefixes are append-only so patches can validate prior contents.
 */
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
	final pendingTypes:Map<String, Bool> = [];

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
		var result:Array<HlNamedSlots> = [for (name => slots in values) {name: name, slots: orderedMap(slots)}];
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
		if (intIndices.exists(value))
			return intIndices.get(value);
		var index = ints.length;
		ints.push(value);
		intIndices.set(value, index);
		return index;
	}

	public function internString(value:String):Int {
		if (stringIndices.exists(value))
			return stringIndices.get(value);
		var index = strings.length;
		strings.push(value);
		stringIndices.set(value, index);
		return index;
	}

	public function internFloat(value:Float):Int {
		var key = Std.string(value);
		if (floatIndices.exists(key))
			return floatIndices.get(key);
		var index = floats.length;
		floats.push(value);
		floatIndices.set(key, index);
		return index;
	}

	public function internType(type:IrType):Int {
		var key = typeKey(type);
		if (typeIndices.exists(key))
			return typeIndices.get(key);
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
		var key = 'enum:${enumDecl.name}';
		if (typeIndices.exists(key) && !pendingTypes.exists(key))
			return typeIndices.get(key);
		var constructors = [
			for (constructor in enumDecl.cases)
				{name: internString(constructor.name), params: [for (param in constructor.params) internType(param)]}
		];
		var index = typeIndices.exists(key) ? typeIndices.get(key) : types.length;
		if (pendingTypes.exists(key)) {
			types[index] = Enum(internString(enumDecl.name), 0, constructors);
			pendingTypes.remove(key);
		} else {
			types.push(Enum(internString(enumDecl.name), 0, constructors));
			typeIndices.set(key, index);
		}
		return index;
	}

	public function internInterface(interfaceDecl:IrInterface):Int {
		var name = interfaceDecl.name, key = 'virt:$name';
		if (typeIndices.exists(key) && !pendingTypes.exists(key))
			return typeIndices.get(key);
		var fields:Array<Null<HlVirtualField>> = [], slots:Map<String, Int> = [], next = 0;
		for (base in interfaceDecl.bases)
			if (interfaceMethodIndices.exists(base)) {
				var inherited = interfaceMethodIndices.get(base);
				for (methodName => slot in inherited) {
					slots.set(methodName, slot);
					if (slot >= next)
						next = slot + 1;
					if (typeIndices.exists('virt:$base')) {
						var baseIndex = typeIndices.get('virt:$base');
						switch types[baseIndex] {
							case Virtual(baseFields):
								if (slot < baseFields.length)
									fields[slot] = baseFields[slot];
							default:
						}
					}
				}
			}
		for (method in interfaceDecl.methods) {
			var slot:Int;
			if (slots.exists(method.name))
				slot = slots.get(method.name);
			else {
				slot = next++;
				slots.set(method.name, slot);
			}
			var type = internFunction(method.arguments, method.result);
			fields[slot] = {name: internString(method.name), type: type};
		}
		var completeFields:Array<HlVirtualField> = [];
		for (field in fields)
			if (field == null) {
				throw 'Interface "$name" has an unassigned virtual slot';
			} else
				completeFields.push(field);
		var index = typeIndices.exists(key) ? typeIndices.get(key) : types.length;
		if (pendingTypes.exists(key)) {
			types[index] = Virtual(completeFields);
			pendingTypes.remove(key);
		} else {
			types.push(Virtual(completeFields));
			typeIndices.set(key, index);
		}
		interfaceMethodIndices.set(name, slots);
		return index;
	}

	public function internObject(object:IrObject, functionIndices:Map<String, Int>):Int {
		if (objectIndices.exists(object.name))
			return objectIndices.get(object.name);
		var fields = [
			for (field in object.fields)
				{name: internString(field.name), type: internType(field.type)}
		], key = 'obj:${object.name}', index = typeIndices.exists(key) ? typeIndices.get(key) : types.length, global = globals.length + 1;
		var base = -1, slots:Map<String, Int> = [], nextSlot = 0;
		if (object.base != null) {
			var baseName = Std.string(object.base);
			var baseKey = 'obj:$baseName';
			if (!typeIndices.exists(baseKey))
				throw 'Object base "$baseName" must be registered before "${object.name}"';
			base = typeIndices.get(baseKey);
			if (objectMethodIndices.exists(baseName))
				for (name => slot in objectMethodIndices.get(baseName)) {
					slots.set(name, slot);
					if (slot >= nextSlot)
						nextSlot = slot + 1;
				}
		}
		var methods:Array<HlObjectMethod> = [];
		for (method in object.methods) {
			var slot:Int;
			if (slots.exists(method.name))
				slot = slots.get(method.name);
			else {
				slot = nextSlot++;
				slots.set(method.name, slot);
			}
			if (!functionIndices.exists(method.functionName))
				throw 'Unknown object method function "${method.functionName}"';
			var functionIndex = functionIndices.get(method.functionName);
			methods.push({name: internString(method.name), functionIndex: functionIndex, prototype: slot});
		}
		var definition:HlTypeDef = Object(internString(object.name), base, global, fields, methods, []);
		if (pendingTypes.exists(key)) {
			types[index] = definition;
			pendingTypes.remove(key);
		} else {
			types.push(definition);
			typeIndices.set(key, index);
		}
		objectIndices.set(object.name, index);
		objectMethodIndices.set(object.name, slots);
		globals.push(index);
		return index;
	}

	public function hasType(key:String):Bool
		return typeIndices.exists(key);

	public function hasInterfaceMethods(name:String):Bool
		return interfaceMethodIndices.exists(name);

	public function hasObjectMethods(name:String):Bool
		return objectMethodIndices.exists(name);

	public function reserveEnum(name:String):Int
		return reserveType('enum:$name');

	public function reserveInterface(name:String):Int
		return reserveType('virt:$name');

	public function reserveObject(name:String):Int
		return reserveType('obj:$name');

	function reserveType(key:String):Int {
		if (typeIndices.exists(key))
			return typeIndices.get(key);
		var index = types.length;
		types.push(HlTypeDef.Simple(HlType.Void));
		typeIndices.set(key, index);
		pendingTypes.set(key, true);
		return index;
	}

	public function internGlobal(name:String, type:IrType):Int {
		if (globalIndices.exists(name))
			return globalIndices.get(name);
		var index = globals.length;
		globals.push(internType(type));
		globalIndices.set(name, index);
		return index;
	}

	public function requireGlobalIndex(name:String):Int {
		if (!globalIndices.exists(name))
			throw 'Unknown static field global "$name"';
		return globalIndices.get(name);
	}

	public function requireObjectMethodIndex(objectName:String, methodName:String):Int {
		if (!objectMethodIndices.exists(objectName))
			throw 'Unknown IR method "$objectName.$methodName"';
		var methods = objectMethodIndices.get(objectName);
		if (!methods.exists(methodName))
			throw 'Unknown IR method "$objectName.$methodName"';
		return methods.get(methodName);
	}

	public function requireInterfaceMethodIndex(interfaceName:String, methodName:String):Int {
		if (!interfaceMethodIndices.exists(interfaceName))
			throw 'Unknown IR method "$interfaceName.$methodName"';
		var methods = interfaceMethodIndices.get(interfaceName);
		if (!methods.exists(methodName))
			throw 'Unknown IR method "$interfaceName.$methodName"';
		return methods.get(methodName);
	}

	public function internFunction(arguments:Array<IrType>, result:IrType):Int {
		var key = 'fun(${[for (a in arguments) typeKey(a)].join(",")})->${typeKey(result)}',
			found = typeIndices.get(key);
		if (typeIndices.exists(key))
			return typeIndices.get(key);
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
