package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.hl.incremental.HlSymbolRequest.HlRuntimeHeader;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.abi.NameRewrite;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlCode.HlVirtualField;
import compiler.hl.HlCode.HlObjectMethod;
import compiler.hl.HlCode.HlObjectField;
import compiler.hl.HlCode.HlEnumConstructor;
import compiler.hl.HlType;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrInterface;
import compiler.ir.model.Ir.IrEnum;

/** Persisted association between a semantic name and an append-only index. */
typedef HlNamedIndex = {
	final name:String;
	final index:Int;
}

/** Persisted ordered member indices owned by one named type. */
typedef HlNamedSlots = {
	final name:String;
	final slots:Array<HlNamedIndex>;
}

/** How many entries each table has. */
typedef HlTableLengths = {
	final ints:Int;
	final floats:Int;
	final strings:Int;
	final types:Int;
	final globals:Int;
}

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
	public var ints(default, null):Array<Int> = [];
	public var floats(default, null):Array<Float> = [];
	public var types(default, null):Array<HlTypeDef> = [];

	/** How many strings this table has: the prefix of `stringEntries` it sees (`string`, `stringTable`). */
	public var stringCount(default, null) = 0;

	/** How many globals this table has: the prefix of `globalEntries` it sees (`globalTable`). */
	public var globalCount(default, null) = 0;

	/** The strings and the globals only ever grow, so forked tables share them (`HlStringEntries`, `HlGlobalEntries`). */
	var stringEntries = new HlStringEntries([], []);

	var globalEntries = new HlGlobalEntries([], [], []);

	/** How many of `globalEntries.stringConstants` this table has, the literals among its `globalCount` globals. */
	var stringConstantCount = 0;

	var intIndices:Map<Int, Int> = [];
	var floatIndices:Map<String, Int> = [];
	var typeIndices:Map<String, Int> = [];

	/**
	 * `typeIndices` by type id (`IrTypeIds`), or -1, so interning a type it already has is an array read. It only learns facts
	 * that hold for every table sharing `typeIndices` (an index never changes once given), so it is shared and copied with
	 * them (`fork`, `writable`), and a server's next build keeps it; `renameTypes` drops it with the keys it rewrites.
	 */
	var typeIndex:Array<Int> = [];
	var objectIndices:Map<String, Int> = [];
	var objectMethodIndices:Map<String, Map<String, Int>> = [];
	var interfaceMethodIndices:Map<String, Map<String, Int>> = [];
	var pendingTypes:Map<String, Bool> = [];
	/** Counts are needed only while reserved boxed descriptors are still being assembled. */
	final pendingEnumCaseCounts:Map<String, Int> = [];

	/**
	 * The groups of tables this table shares with a fork (`fork`): a group is copied before its first change, so changing one
	 * table copies only its own. The strings and globals are not among them: forks share those for good, each seeing its own
	 * prefix, and one that is not at their end copies its prefix before it appends (`appendableStrings`).
	 */
	var shared = 0;

	static inline final INTS = 1;
	static inline final FLOATS = 2;
	static inline final TYPES = 4;
	static inline final OBJECTS = 8;
	static inline final ALL = 15;

	public function new() {}

	public function copy():HlSymbolTable {
		var result = new HlSymbolTable();
		for (value in ints)
			result.internInt(value);
		result.stringEntries = stringEntries.prefix(stringCount);
		result.stringCount = stringCount;
		for (value in floats)
			result.internFloat(value);
		for (index in 0...types.length)
			result.types.push(types[index]);
		copyMap(typeIndices, result.typeIndices);
		result.globalEntries = globalEntries.prefix(globalCount, stringConstantCount);
		result.globalCount = globalCount;
		result.stringConstantCount = stringConstantCount;
		copyMap(objectIndices, result.objectIndices);
		copyNestedMap(objectMethodIndices, result.objectMethodIndices);
		copyNestedMap(interfaceMethodIndices, result.interfaceMethodIndices);
		return result;
	}

	public function fork():HlSymbolTable {
		var result = new HlSymbolTable();
		result.ints = ints;
		result.floats = floats;
		result.types = types;
		result.stringEntries = stringEntries;
		result.stringCount = stringCount;
		result.globalEntries = globalEntries;
		result.globalCount = globalCount;
		result.stringConstantCount = stringConstantCount;
		result.intIndices = intIndices;
		result.floatIndices = floatIndices;
		result.typeIndices = typeIndices;
		result.typeIndex = typeIndex;
		result.objectIndices = objectIndices;
		result.objectMethodIndices = objectMethodIndices;
		result.interfaceMethodIndices = interfaceMethodIndices;
		result.pendingTypes = pendingTypes;
		shared = ALL;
		result.shared = ALL;
		return result;
	}

	/**
	 * Makes this table a fork of `other` (see `fork`), dropping what it held: a build that extends the last build's tables
	 * (`HlLoweredTables`) works on them without changing them for the tables that hold them.
	 */
	public function shareFrom(other:HlSymbolTable):Void {
		var forked = other.fork();
		ints = forked.ints;
		floats = forked.floats;
		types = forked.types;
		stringEntries = forked.stringEntries;
		stringCount = forked.stringCount;
		globalEntries = forked.globalEntries;
		globalCount = forked.globalCount;
		stringConstantCount = forked.stringConstantCount;
		intIndices = forked.intIndices;
		floatIndices = forked.floatIndices;
		typeIndices = forked.typeIndices;
		typeIndex = forked.typeIndex;
		objectIndices = forked.objectIndices;
		objectMethodIndices = forked.objectMethodIndices;
		interfaceMethodIndices = forked.interfaceMethodIndices;
		pendingTypes = forked.pendingTypes;
		pendingEnumCaseCounts.clear();
		shared = ALL;
	}

	public function lengths():HlTableLengths
		return {
			ints: ints.length,
			floats: floats.length,
			strings: stringCount,
			types: types.length,
			globals: globalCount
		};

	public static function sameLengths(left:HlTableLengths, right:HlTableLengths):Bool
		return left.ints == right.ints && left.floats == right.floats && left.strings == right.strings
			&& left.types == right.types && left.globals == right.globals;

	/**
	 * Whether this table starts with the entries of `prefix`, and names its globals as `prefix` does. Each other key a table maps
	 * is answered by its entry, so a table that starts with the same entries answers every request of `prefix` the same; the keys
	 * that only name another entry (a nullable class as `Dynamic`) add nothing either way. A global's entry is only its type, so
	 * its name is compared too: a renamed static field leaves every entry as it was.
	 */
	public function startsWith(prefix:HlSymbolTable):Bool {
		if (ints.length < prefix.ints.length || floats.length < prefix.floats.length
			|| stringCount < prefix.stringCount || types.length < prefix.types.length
			|| globalCount < prefix.globalCount)
			return false;
		for (index in 0...prefix.ints.length)
			if (ints[index] != prefix.ints[index])
				return false;
		for (index in 0...prefix.floats.length)
			if (!sameFloat(floats[index], prefix.floats[index]))
				return false;
		if (stringEntries != prefix.stringEntries) {
			var values = stringEntries.values, prefixValues = prefix.stringEntries.values;
			for (index in 0...prefix.stringCount)
				if (values[index] != prefixValues[index])
					return false;
		}
		if (globalEntries != prefix.globalEntries) {
			var globals = globalEntries.types, prefixGlobals = prefix.globalEntries.types;
			for (index in 0...prefix.globalCount)
				if (globals[index] != prefixGlobals[index])
					return false;
			var indices = globalEntries.indices;
			for (name => index in prefix.globalEntries.indices)
				if (index < prefix.globalCount && indices.get(name) != index)
					return false;
		}
		for (index in 0...prefix.types.length)
			if (!sameType(types[index], prefix.types[index]))
				return false;
		return true;
	}

	/** Whether two type definitions are the same, with the same indices. */
	public static function sameType(left:HlTypeDef, right:HlTypeDef):Bool
		return switch [left, right] {
			case [Simple(a), Simple(b)]: a == b;
			case [EnumTag(a, aGlobals), EnumTag(b, bGlobals)]: a == b && sameInts(aGlobals, bGlobals);
			case [Parameterized(a, aParameter), Parameterized(b, bParameter)]: a == b && aParameter == bParameter;
			case [Abstract(a), Abstract(b)]: a == b;
			case [Function(aArguments, a), Function(bArguments, b)] | [Method(aArguments, a), Method(bArguments, b)]:
				a == b && sameInts(aArguments, bArguments);
			case [
				Object(aName, aBase, aGlobal, aFields, aMethods, aBindings),
				Object(bName, bBase, bGlobal, bFields, bMethods, bBindings)
			]:
				aName == bName && aBase == bBase && aGlobal == bGlobal && sameFields(aFields, bFields)
					&& sameMethods(aMethods, bMethods) && sameInts(aBindings, bBindings);
			case [
				Structure(aName, aGlobal, aFields, aMethods, aBindings),
				Structure(bName, bGlobal, bFields, bMethods, bBindings)
			]:
				aName == bName && aGlobal == bGlobal && sameFields(aFields, bFields) && sameMethods(aMethods, bMethods)
					&& sameInts(aBindings, bBindings);
			case [Virtual(aName, aFields), Virtual(bName, bFields)]:
				if (aName != bName || aFields.length != bFields.length) false;
				else {
					var same = true;
					for (index in 0...aFields.length)
						if (aFields[index].name != bFields[index].name || aFields[index].type != bFields[index].type)
							same = false;
					same;
				}
			case [Enum(aName, aGlobal, aConstructors), Enum(bName, bGlobal, bConstructors)]:
				if (aName != bName || aGlobal != bGlobal || aConstructors.length != bConstructors.length) false;
				else {
					var same = true;
					for (index in 0...aConstructors.length)
						if (aConstructors[index].name != bConstructors[index].name
							|| !sameInts(aConstructors[index].params, bConstructors[index].params))
							same = false;
					same;
				}
			default: false;
		};

	/** The table pools floats by their bits: a NaN is never taken for another, nor 0 for -0. */
	public static function sameFloat(left:Float, right:Float):Bool
		return left == right && (left != 0 || 1 / left == 1 / right);

	static function sameInts(left:Array<Int>, right:Array<Int>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function sameFields(left:Array<HlObjectField>, right:Array<HlObjectField>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index].name != right[index].name || left[index].type != right[index].type)
				return false;
		return true;
	}

	static function sameMethods(left:Array<HlObjectMethod>, right:Array<HlObjectMethod>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a.name != b.name || a.functionIndex != b.functionIndex || a.prototype != b.prototype)
				return false;
		}
		return true;
	}

	function ensureWritable():Void
		writable(ALL);

	/** Copies the groups of `groups` this table shares, so changing them leaves the tables it shares them with as they are. */
	function writable(groups:Int):Void {
		var copied = shared & groups;
		if (copied == 0)
			return;
		if (copied & INTS != 0) {
			ints = ints.copy();
			intIndices = [for (key => value in intIndices) key => value];
		}
		if (copied & FLOATS != 0) {
			floats = floats.copy();
			floatIndices = [for (key => value in floatIndices) key => value];
		}
		if (copied & TYPES != 0) {
			types = types.copy();
			typeIndices = [for (key => value in typeIndices) key => value];
			typeIndex = typeIndex.copy();
			pendingTypes = [for (key => value in pendingTypes) key => value];
		}
		if (copied & OBJECTS != 0) {
			objectIndices = [for (key => value in objectIndices) key => value];
			var objectMethods:Map<String, Map<String, Int>> = [],
				interfaceMethods:Map<String, Map<String, Int>> = [];
			copyNestedMap(objectMethodIndices, objectMethods);
			copyNestedMap(interfaceMethodIndices, interfaceMethods);
			objectMethodIndices = objectMethods;
			interfaceMethodIndices = interfaceMethods;
		}
		shared &= ~copied;
	}

	/**
	 * Lets this table append strings: a table that does not end where the shared strings end (a fork older than another that
	 * appended) copies its prefix, so the strings past it, which it never had, stay the other's.
	 */
	function appendableStrings():Void
		if (stringCount != stringEntries.values.length)
			stringEntries = stringEntries.prefix(stringCount);

	/** Lets this table append globals, as `appendableStrings` strings. */
	function appendableGlobals():Void
		if (globalCount != globalEntries.types.length)
			globalEntries = globalEntries.prefix(globalCount, stringConstantCount);

	/** String `index`, below `stringCount`. */
	public inline function string(index:Int):String
		return stringEntries.values[index];

	/**
	 * The strings as a module holds them (`HlCode.strings`): this table's, which no later append reaches. Tables with as many
	 * strings have the same ones, so they share it.
	 */
	public function stringTable():Array<String> {
		var entries = stringEntries;
		if (entries.table.length != stringCount)
			entries.table = entries.values.slice(0, stringCount);
		return entries.table;
	}

	/** The type of each global, as `stringTable` gives the strings (`HlCode.globals`). */
	public function globalTable():Array<Int> {
		var entries = globalEntries;
		if (entries.table.length != globalCount)
			entries.table = entries.types.slice(0, globalCount);
		return entries.table;
	}

	/** The index of string `value`, or null when this table does not have it. */
	inline function stringIndex(value:String):Null<Int> {
		var index = stringEntries.indices.get(value);
		return index != null && index < stringCount ? index : null;
	}

	/** The index of the global named `name`, or null when this table does not have it. */
	inline function globalIndex(name:String):Null<Int> {
		var index = globalEntries.indices.get(name);
		return index != null && index < globalCount ? index : null;
	}

	public function exportState():HlSymbolState
		return {
			ints: ints.copy(),
			strings: stringEntries.values.slice(0, stringCount),
			floats: floats.copy(),
			types: types.copy(),
			globals: globalEntries.types.slice(0, globalCount),
			typeIndices: orderedMap(typeIndices),
			globalIndices: orderedMap(namedGlobals()),
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
				throw new InternalError("Duplicate persisted integer symbol");
			else
				result.intIndices.set(state.ints[index], index);
		var strings = result.stringEntries;
		for (value in state.strings)
			strings.values.push(value);
		for (index in 0...state.strings.length)
			if (strings.indices.exists(state.strings[index]))
				throw new InternalError("Duplicate persisted string symbol");
			else
				strings.indices.set(state.strings[index], index);
		result.stringCount = state.strings.length;
		for (value in state.floats)
			result.floats.push(value);
		for (index in 0...state.floats.length) {
			// The key `internFloat` looks constants up by: a decoded table must find the floats it already holds.
			var key = floatKey(state.floats[index]);
			if (result.floatIndices.exists(key))
				throw new InternalError("Duplicate persisted float symbol");
			else
				result.floatIndices.set(key, index);
		}
		for (type in state.types)
			result.types.push(type);
		var globals = result.globalEntries;
		for (global in state.globals)
			globals.types.push(global);
		result.globalCount = state.globals.length;
		loadMap(state.typeIndices, result.typeIndices, "type");
		loadMap(state.globalIndices, globals.indices, "global");
		for (constant in collectStringConstants(globals.indices))
			globals.stringConstants.push(constant);
		result.stringConstantCount = globals.stringConstants.length;
		loadMap(state.objectIndices, result.objectIndices, "object");
		loadNestedMap(state.objectMethodIndices, result.objectMethodIndices, "object method");
		loadNestedMap(state.interfaceMethodIndices, result.interfaceMethodIndices, "interface method");
		return result;
	}

	static function orderedMap(values:Map<String, Int>):Array<HlNamedIndex> {
		var result:Array<HlNamedIndex> = [for (name => index in values) {
			name: name, index: index
		}];
		result.sort((a, b) -> Reflect.compare(a.name, b.name));
		return result;
	}

	static function orderedNestedMap(values:Map<String, Map<String, Int>>):Array<HlNamedSlots> {
		var result:Array<HlNamedSlots> = [for (name => slots in values) {
			name: name, slots: orderedMap(slots)
		}];
		result.sort((a, b) -> Reflect.compare(a.name, b.name));
		return result;
	}

	static function loadMap(entries:Array<HlNamedIndex>, target:Map<String, Int>, kind:String):Void
		for (entry in entries) {
			if (entry.name.length == 0 || entry.index < 0 || target.exists(entry.name))
				throw new InternalError('Invalid persisted $kind index');
			target.set(entry.name, entry.index);
		}

	static function loadNestedMap(entries:Array<HlNamedSlots>, target:Map<String, Map<String, Int>>, kind:String):Void
		for (entry in entries) {
			if (entry.name.length == 0 || target.exists(entry.name))
				throw new InternalError('Invalid persisted $kind owner');
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
		writable(INTS);
		var index = ints.length;
		ints.push(value);
		intIndices.set(value, index);
		return index;
	}

	public function internString(value:String):Int {
		var known = stringIndex(value);
		if (known != null)
			return known;
		appendableStrings();
		var index = stringCount;
		stringEntries.values.push(value);
		stringEntries.indices.set(value, index);
		stringCount = index + 1;
		return index;
	}

	/**
	 * Floats are pooled by their exact IEEE-754 bits. `Std.string` is not a round-trip
	 * representation on every host (HashLink prints 0.49999999999999994 as "0.5"), so a
	 * string key merged distinct constants when the compiler itself ran on HashLink.
	 */
	public function internFloat(value:Float):Int {
		var key = floatKey(value);
		if (floatIndices.exists(key))
			return floatIndices.get(key);
		writable(FLOATS);
		var index = floats.length;
		floats.push(value);
		floatIndices.set(key, index);
		return index;
	}

	static function floatKey(value:Float):String {
		var bits = haxe.io.Bytes.alloc(8);
		bits.setDouble(0, value);
		return bits.getInt32(0) + ":" + bits.getInt32(4);
	}

	public static inline final STRING_BYTES_FIELD = 0;
	public static inline final STRING_LENGTH_FIELD = 1;

	/** Compiler-only references used to access runtime headers with pointer-size-aware HashLink instructions. */
	public function internReference(type:IrType):Int
		return internReferenceId(IrTypeIds.id(type));

	/** `internReference` of the type with id `id`; `key` is its `typeKey` when the caller has it already (`HlRequestAnswers`). */
	public function internReferenceId(id:Int, ?key:String):Int {
		var reference = "ref:" + (key ?? typeKey(IrTypeIds.type(id)));
		if (typeIndices.exists(reference))
			return typeIndices.get(reference);
		writable(TYPES);
		var parameter = internTypeId(id), index = types.length;
		types.push(HlTypeDef.Parameterized(HlType.Ref, parameter));
		typeIndices.set(reference, index);
		return index;
	}

	/** Release-only tags with no boxed use have exactly the ordinary I32 runtime type. */
	public function internScalarEnumTag(name:String):Void {
		var key = typeKey(EnumTag(name));
		if (typeIndices.exists(key)) return;
		writable(TYPES);
		typeIndices.set(key, internType(I32));
	}

	public function internType(type:IrType):Int
		return internTypeId(IrTypeIds.id(type));

	/** `internType` of the type with id `id`; `key` is its `typeKey` when the caller has it already (`HlRequestAnswers`). */
	public function internTypeId(id:Int, ?key:String):Int {
		var known = id < typeIndex.length ? typeIndex[id] : -1;
		if (known >= 0)
			return known;
		var type = IrTypeIds.type(id), index = internTypeByKey(type, key ?? typeKey(type));
		while (typeIndex.length <= id)
			typeIndex.push(-1);
		typeIndex[id] = index;
		return index;
	}

	function internTypeByKey(type:IrType, key:String):Int {
		if (typeIndices.exists(key))
			return typeIndices.get(key);
		writable(TYPES);
		switch type {
			case Abstract(_) if (compiler.ir.passes.scalars.IrHlScalarRef.element(type) != null):
				var index = internReference(compiler.ir.passes.scalars.IrHlScalarRef.element(type));
				typeIndices.set(key, index);
				return index;
			case EnumTag(name):
				var boxed = typeIndices.get('enum:$name');
				if (boxed == null)
					throw new InternalError('Enum tag "$name" must be registered before use');
				var caseCount = switch types[boxed] {
					case HlTypeDef.Enum(_, _, constructors): constructors.length;
					default:
						var pendingCount = pendingEnumCaseCounts.get(name);
						if (pendingCount == null)
							throw new InternalError('Missing enum tag declaration "$name"');
						pendingCount;
				};
				var cacheGlobals = [for (i in 0...caseCount) internEnumConstant(name, i)];
				var index = types.length;
				types.push(HlTypeDef.EnumTag(boxed, cacheGlobals));
				typeIndices.set(key, index);
				return index;
			case Function(arguments, result):
				return internFunctionByKey(arguments, result, key);
			case Enum(name):
				throw new InternalError('Enum type "$name" must be registered before use');
			case Virtual(name):
				throw new InternalError('Virtual type "$name" must be registered before use');
			case Nullable(element):
				// Nullable value objects retain their payload type in IR, but still use the previous Dyn ABI.
				// HashLink's HNULL describes primitive boxes, not an inline nullable HSTRUCT.
				switch element {
					case Obj(_):
						var dynamicIndex = internType(Dyn);
						typeIndices.set(key, dynamicIndex);
						return dynamicIndex;
					default:
				}
				// HashLink's own Null<T>: the same boxed representation as a dynamic value, with the primitive recorded.
				var parameter = internType(element);
				var nullIndex = types.length;
				types.push(HlTypeDef.Parameterized(HlType.Null, parameter));
				typeIndices.set(key, nullIndex);
				return nullIndex;
			default:
		}
		switch type {
			case Bytes:
				return internStringObject(key);
			default:
		}
		var index = types.length;
		if (typeKey(type).indexOf("obj:") == 0)
			throw new InternalError('Object type "$type" must be registered before use');
		types.push(switch type {
			case ManagedBytes: HlTypeDef.Abstract(internString("realtime_bytes"));
			case RawPtr: HlTypeDef.Simple(HlType.Bytes);
			case Abstract(name): HlTypeDef.Abstract(internString(name));
			case Iterator(_): HlTypeDef.Abstract(internString("realtime_iterator"));
			default: HlTypeDef.Simple(switch type {
					case Void: HlType.Void;
					case I32: HlType.I32;
					case EnumTag(_): throw new InternalError("Enum tag must be interned with its descriptor");
					case I64: HlType.I64;
					case Bool: HlType.Bool;
					case F32: HlType.F32;
					case F64: HlType.F64;
					case Bytes: throw new InternalError('String type must be interned as an object');
					case RawPtr: HlType.Bytes;
					case ManagedBytes: throw new InternalError('Managed byte type must be handled by the outer type switch');
					case Dyn: HlType.Dyn;
					case Nullable(_): throw new InternalError('Nullable type must be handled by the outer type switch');
					case TypeRef: HlType.Type;
					case Array(_): HlType.Array;
					case Iterator(_): throw new InternalError('Iterator type must be handled by the outer type switch');
					case Obj(name): throw new InternalError('Object type "$name" must be registered before use');
					case Abstract(name): throw new InternalError('Abstract type "$name" must be handled by the outer type switch');
					case Virtual(name): throw new InternalError('Virtual type "$name" must be registered before use');
					case Function(_, _): throw new InternalError('Function type must be interned with internFunction');
					case Enum(name): throw new InternalError('Enum type "$name" must be registered before use');
				});
		});
		typeIndices.set(key, index);
		return index;
	}

	/**
	 * HashLink's String layout, `_STRING` in native signatures: UTF-16 data plus its length in code units, so length and
	 * indexing never rescan the data, and the hash string maps keep in it once computed (0 until then). The hash has no name,
	 * so reflection and dynamic access do not see it, as in a stock String. Natives recognize the type by name and shape.
	 */
	function internStringObject(key:String):Int {
		var fields:Array<HlObjectField> = [
			{name: internString("bytes"), type: internType(RawPtr)},
			{name: internString("length"), type: internType(I32)},
			{name: internString(""), type: internType(I32)}
		],
			index = types.length;
		types.push(HlTypeDef.Object(internString("String"), -1, 0, fields, [], []));
		typeIndices.set(key, index);
		return index;
	}

	/**
	 * An object type laid out like the runtime header `kind`, so a fast path reads and writes its fields with one field access each
	 * instead of addressing them as slots. No value ever has this type; a register is cast to it.
	 */
	public function internRuntimeHeader(kind:HlRuntimeHeader):Int {
		var key = RUNTIME_HEADER_PREFIX + Std.string(kind);
		if (typeIndices.exists(key))
			return typeIndices.get(key);
		writable(TYPES);
		var fields:Array<HlObjectField> = switch kind {
			case BytesHeader: [
				{name: internString("data"), type: internType(RawPtr)},
				{name: internString("length"), type: internType(I32)}
			];
			case ArrayHeader: [
				{name: internString("elementType"), type: internType(RawPtr)},
				{name: internString("size"), type: internType(I32)},
				{name: internString("capacity"), type: internType(I32)}
			];
		},
			index = types.length;
		types.push(HlTypeDef.Object(internString(key), -1, 0, fields, [], []));
		typeIndices.set(key, index);
		return index;
	}

	/** Length in UTF-16 code units, independent of the host's own String encoding. */
	public static function utf16Length(value:String):Int {
		var bytes = haxe.io.Bytes.ofString(value), length = 0;
		for (index in 0...bytes.length) {
			var byte = bytes.get(index);
			if ((byte & 0xC0) != 0x80)
				length += byte >= 0xF0 ? 2 : 1;
		}
		return length;
	}

	public function internEnum(enumDecl:IrEnum):Int {
		var key = 'enum:${enumDecl.name}';
		if (typeIndices.exists(key) && !pendingTypes.exists(key)) {
			pendingEnumCaseCounts.remove(enumDecl.name);
			return typeIndices.get(key);
		}
		ensureWritable();
		var constructors:Array<HlEnumConstructor> = [for (constructor in enumDecl.cases)
			{
				name: internString(constructor.name), params: [for (param in constructor.params) internType(param)]
			}];
		var index = typeIndices.exists(key) ? typeIndices.get(key) : types.length;
		if (pendingTypes.exists(key)) {
			types[index] = Enum(internString(enumDecl.name), 0, constructors);
			pendingTypes.remove(key);
		} else {
			types.push(Enum(internString(enumDecl.name), 0, constructors));
			typeIndices.set(key, index);
		}
		pendingEnumCaseCounts.remove(enumDecl.name);
		return index;
	}

	public function internInterface(interfaceDecl:IrInterface):Int {
		var name = interfaceDecl.name, key = 'virt:$name';
		if (typeIndices.exists(key) && !pendingTypes.exists(key))
			return typeIndices.get(key);
		ensureWritable();
		var fields:Array<Null<HlVirtualField>> = [], slots:Map<String, Int> = [], next = 0;
		for (base in interfaceDecl.bases)
			if (interfaceMethodIndices.exists(base)) {
				var inherited = interfaceMethodIndices.get(base);
				for (methodName => slot in inherited) {
					slots.set(methodName, slot);
					if (slot >= next)
						next = slot + 1;
					var baseKey = 'virt:$base';
					if (typeIndices.exists(baseKey)) {
						var baseIndex = typeIndices.get(baseKey);
						switch types[baseIndex] {
							case Virtual(_, baseFields):
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
				throw new InternalError('Interface "$name" has an unassigned virtual slot');
			} else
				completeFields.push(field);
		var contract = [name];
		for (base in interfaceDecl.bases) {
			var baseIndex = internType(IrType.Virtual(base));
			switch types[baseIndex] {
				case Virtual(baseIdentity, _): contract.push(string(baseIdentity));
				default: throw new InternalError('Base interface "$base" has no virtual identity');
			}
		}
		for (method in interfaceDecl.methods)
			contract.push(method.name + ":" + IrTypeIdentity.listText(method.arguments) + "->"
				+ IrTypeIdentity.text(method.result));
		var identity = internString(name + "#" + compiler.core.TextDigest.sha256(contract.join("\n")));
		var index = typeIndices.exists(key) ? typeIndices.get(key) : types.length;
		if (pendingTypes.exists(key)) {
			types[index] = Virtual(identity, completeFields);
			pendingTypes.remove(key);
		} else {
			types.push(Virtual(identity, completeFields));
			typeIndices.set(key, index);
		}
		interfaceMethodIndices.set(name, slots);
		return index;
	}

	/**
	 * `reserve` unnamed Dynamic fields go after the object's own fields and interface caches: room a live patch can give
	 * fields added later, in instances that already exist (see `assignReservedField`).
	 */
	public function internObject(object:IrObject, functionIndices:Map<String, Int>, ?valueObjects:Map<String, Bool>,
			?interfaceSlots:Array<String>,
			reserve:Int = 0, ?typedEntries:Array<compiler.ir.model.Ir.IrObjectMethod>):Int {
		if (objectIndices.exists(object.name))
			return objectIndices.get(object.name);
		ensureWritable();
		var fields:Array<HlObjectField> = [for (field in object.fields)
			{
				name: internString(field.name),
				type: internObjectFieldType(field.type, valueObjects, compiler.ir.model.IrFieldStorage.scalar(field))
			}];
		if (interfaceSlots != null)
			for (slot in interfaceSlots) {
				var virtualKey = 'virt:$slot';
				if (!typeIndices.exists(virtualKey))
					throw new InternalError('Interface "$slot" must be registered before "${object.name}"');
				// HashLink recognizes an unnamed field of the interface's type as the cache for its virtual.
				// Read the index before interning: the call could change the table the existence check just covered.
				var virtualType = typeIndices.get(virtualKey);
				fields.push({name: internString(""), type: virtualType});
			}
		if (reserve > 0 && !object.isValue) {
			var reserved = internType(IrType.Dyn), unnamed = internString("");
			for (_ in 0...reserve)
				fields.push({name: unnamed, type: reserved});
		}
		var key = 'obj:${object.name}',
			index = typeIndices.exists(key) ? typeIndices.get(key) : types.length,
			global = globalCount + 1;
		var base = -1, slots:Map<String, Int> = [], nextSlot = 0;
		if (object.base != null) {
			var baseName = Std.string(object.base);
			var baseKey = 'obj:$baseName';
			if (!typeIndices.exists(baseKey))
				throw new InternalError('Object base "$baseName" must be registered before "${object.name}"');
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
			if (!functionIndices.exists(method.functionName.name))
				throw new InternalError('Unknown object method function "${method.functionName}"');
			var functionIndex = functionIndices.get(method.functionName.name);
			methods.push({name: internString(method.name), functionIndex: functionIndex, prototype: slot});
		}
		if (typedEntries != null) for (entry in typedEntries) {
			var typedIndex = functionIndices.get(entry.functionName.name);
			if (typedIndex == null) throw new InternalError('Unknown typed interface entry "${entry.functionName}"');
			methods.push({
				name: internString(entry.name),
				functionIndex: typedIndex,
				prototype: compiler.hl.HlCode.TYPED_METHOD_PROTOTYPE
			});
		}

		var definition:HlTypeDef = object.isValue ? Structure(internString(object.name), global, fields, methods,
			[]) : Object(internString(object.name), base, global, fields, methods, []);
		if (pendingTypes.exists(key)) {
			types[index] = definition;
			pendingTypes.remove(key);
		} else {
			types.push(definition);
			typeIndices.set(key, index);
		}
		objectIndices.set(object.name, index);
		objectMethodIndices.set(object.name, slots);
		appendGlobal(index);
		return index;
	}

	/**
	 * Gives types new names as `rewrite` says (see `compiler.abi.LambdaAlignment`): the keys of objects, and of the types made
	 * from them (`fun(obj:...)`, `null:obj:...`), move to the new names and keep their indices. A name the rewrite frees is
	 * interned afresh when a build uses it.
	 *
	 * The definitions keep the names they were published with, on purpose. This table mirrors the types the running module
	 * holds, and every patch carries a hash of the published type prefix, names included, which the module checks
	 * (`hash_type_prefix` in hlpatch.c: "Patch symbol prefix hash does not match module"); a patch cannot rename a loaded
	 * type either, it only appends. So a renamed object's definition still carries its old name, and once a build interns
	 * the freed name afresh, a module written from this table has two types with that name. Nothing resolves these types by
	 * name: HashLink addresses types by index, the program never looks a closure environment up by its name, and a reload
	 * discards the table (`HlModuleAssembler.discardPublishedSymbols`), so the stale names only show in tools that print
	 * type names.
	 */
	public function renameTypes(rewrite:NameRewrite):Array<{from:String, to:String}> {
		if (rewrite.isEmpty())
			return [];
		var renamed:Array<{from:String, to:String}> = [];
		for (name => index in objectIndices) {
			var next = rewrite.apply(name);
			if (next == name)
				continue;
			renamed.push({from: name, to: next});
			// A module of sections keys an object's class value by the object's key (`HlSectionWriter.globalKey`).
			switch types[index] {
				case Object(_, _, global, _, _, _) | Structure(_, global, _, _, _) if (global > 0):
					renamed.push({from: CLASS_VALUE + name, to: CLASS_VALUE + next});
				default:
			}
		}
		renamed.sort((left, right) -> Reflect.compare(left.from, right.from));
		ensureWritable();
		typeIndices = rewrite.keys(typeIndices);
		typeIndex = [];
		objectIndices = rewrite.keys(objectIndices);
		var methods:Map<String, Map<String, Int>> = [];
		for (name => slots in objectMethodIndices)
			methods.set(rewrite.apply(name), slots);
		objectMethodIndices = methods;
		var pending:Map<String, Bool> = [];
		for (key => value in pendingTypes)
			pending.set(rewrite.apply(key), value);
		pendingTypes = pending;
		return renamed;
	}

	/** The key prefix of an object's class value global in a module of sections (`HlSectionWriter.globalKey`). */
	public static inline final CLASS_VALUE = "$class:";

	/**
	 * The objects a rename (`renameTypes`) gave names other than the ones their definitions keep, by type index: a module of
	 * sections keys them by the name they have now, so the name the rename freed can key the type a build interns afresh.
	 */
	public function renamedTypeKeys():Map<Int, String> {
		var keys:Map<Int, String> = [];
		for (name => index in objectIndices)
			switch types[index] {
				case Object(defined, _, _, _, _, _) | Structure(defined, _, _, _, _) if (string(defined) != name):
					keys.set(index, name);
				default:
			}
		return keys;
	}

	/** The published definition of object `name`, or null when no published type has that name. */
	public function objectDefinition(name:String):Null<{index:Int, definition:HlTypeDef}> {
		var index = objectIndices.get(name);
		return index == null ? null : {index: index, definition: types[index]};
	}

	/** Slot indices of the methods `name` dispatches through its prototype, its own and inherited, or null for an unknown object. */
	public function objectMethodSlots(name:String):Null<Map<String, Int>>
		return objectMethodIndices.get(name);

	/** Whether `field` is a reserved slot no field has taken yet. */
	public function isReservedField(field:HlObjectField):Bool
		return string(field.name) == "" && switch types[field.type] {
			case Simple(kind): kind == HlType.Dyn;
			default: false;
		};

	/**
	 * Gives field `fieldName` of type `fieldType` the first free reserved slot among object `objectName`'s own fields,
	 * returning its index there, or -1 when every slot is taken. The definition is replaced, never changed in place:
	 * forked tables share definitions.
	 */
	public function assignReservedField(objectName:String, fieldName:String, fieldType:Int):Int {
		var found = objectDefinition(objectName);
		if (found == null)
			return -1;
		switch found.definition {
			case Object(name, base, global, fields, methods, bindings):
				for (index in 0...fields.length)
					if (isReservedField(fields[index])) {
						ensureWritable();
						var next = fields.copy();
						next[index] = {name: internString(fieldName), type: fieldType};
						types[found.index] = Object(name, base, global, next, methods, bindings);
						return index;
					}
			default:
		}
		return -1;
	}

	/**
	 * HashLink's index of field `fieldName` declared by object `objectName`: the fields of its bases come first. Null when
	 * the object's published type has no field of that name.
	 */
	public function objectFieldIndex(objectName:String, fieldName:String):Null<Int> {
		var found = objectDefinition(objectName);
		if (found == null)
			return null;
		var fields:Array<HlObjectField> = [];
		switch found.definition {
			case Object(_, _, _, own, _, _):
				fields = own;
			case Structure(_, _, own, _, _):
				fields = own;
			default:
		}
		for (index in 0...fields.length)
			if (string(fields[index].name) == fieldName)
				return inheritedFieldCount(found.definition) + index;
		return null;
	}

	function inheritedFieldCount(definition:HlTypeDef):Int
		return switch definition {
			case Object(_, base, _, _, _, _) if (base >= 0): totalFieldCount(types[base]);
			default: 0;
		};

	function totalFieldCount(definition:HlTypeDef):Int
		return switch definition {
			case Object(_, _, _, fields, _, _): inheritedFieldCount(definition) + fields.length;
			case Structure(_, _, fields, _, _): fields.length;
			default: 0;
		};

	public function internObjectFieldType(type:IrType, valueObjects:Null<Map<String, Bool>>,
			nativeLayout:Null<compiler.ir.model.Ir.IrScalarStorage>):Int {
		return switch type {
			case Obj(name) if (valueObjects != null && valueObjects.exists(name)):
				var parameter = internType(type), key = 'packed:obj:$name';
				if (typeIndices.exists(key)) typeIndices.get(key);
				else {
					writable(TYPES);
					var index = types.length;
					types.push(Parameterized(HlType.Packed, parameter));
					typeIndices.set(key, index);
					index;
				}
			default:
				var nativeStorageType = internNativeFieldStorageType(type, nativeLayout);
				nativeStorageType == null ? internType(type) : nativeStorageType;
		};
	}

	/** Returns the HashLink type used for native field storage when it is narrower than the IR value type. */
	public function internNativeFieldStorageType(type:IrType,
			nativeLayout:Null<compiler.ir.model.Ir.IrScalarStorage>):Null<Int> {
		if (nativeLayout == null)
			return null;
		return switch type {
			case I32 if (nativeLayout.size == 1): internStorageType("ui8", HlType.Ui8);
			case I32 if (nativeLayout.size == 2): internStorageType("ui16", HlType.Ui16);
			case I64 if (nativeLayout.size == 4): internStorageType("i32", HlType.I32);
			default: null;
		};
	}

	function internStorageType(key:String, type:HlType):Int {
		var typeKey = 'native-storage:$key';
		if (typeIndices.exists(typeKey))
			return typeIndices.get(typeKey);
		writable(TYPES);
		var index = types.length;
		types.push(HlTypeDef.Simple(type));
		typeIndices.set(typeKey, index);
		return index;
	}

	public function hasType(key:String):Bool
		return typeIndices.exists(key);

	public function hasInterfaceMethods(name:String):Bool
		return interfaceMethodIndices.exists(name);

	public function hasObjectMethods(name:String):Bool
		return objectMethodIndices.exists(name);

	public function reserveEnum(declaration:IrEnum):Int {
		pendingEnumCaseCounts.set(declaration.name, declaration.cases.length);
		return reserveType('enum:${declaration.name}');
	}

	public function reserveInterface(name:String):Int
		return reserveType('virt:$name');

	public function reserveObject(name:String):Int
		return reserveType('obj:$name');

	function reserveType(key:String):Int {
		if (typeIndices.exists(key))
			return typeIndices.get(key);
		writable(TYPES);
		var index = types.length;
		types.push(HlTypeDef.Simple(HlType.Void));
		typeIndices.set(key, index);
		pendingTypes.set(key, true);
		return index;
	}

	public function internGlobal(name:String, type:IrType):Int {
		var known = globalIndex(name);
		if (known != null)
			return known;
		// HFUN globals are raw-function slots: the VM initializes them with a code pointer, not a closure.
		// Data globals hold nullable closure references. HNULL retains the signature without adding a box.
		var storage = switch type {
			case Function(_, _): Nullable(type);
			default: type;
		};
		var index = appendGlobal(internType(storage));
		globalEntries.indices.set(name, index);
		if (StringTools.startsWith(name, STRING_CONSTANT_PREFIX)) {
			globalEntries.stringConstants.push({global: index, value: name.substr(STRING_CONSTANT_PREFIX.length)});
			stringConstantCount++;
		}
		return index;
	}

	/** Adds a global of type `type`, named or not, and returns its index. */
	function appendGlobal(type:Int):Int {
		appendableGlobals();
		var index = globalCount;
		globalEntries.types.push(type);
		globalCount = index + 1;
		return index;
	}

	/** Globals named after a string literal hold that literal's String object, created once when the module loads. */
	public static inline final STRING_CONSTANT_PREFIX = "$string:";

	/** Globals named after an enum constructor without fields hold the one value it denotes, made the first time it is used. */
	public static inline final ENUM_CONSTANT_PREFIX = "$enum:";

	public function internEnumConstant(enumName:String, constructor:Int):Int
		return internGlobal(ENUM_CONSTANT_PREFIX + enumName + ":" + constructor, IrType.Enum(enumName));

	public function internStringConstant(value:String):Int
		return internGlobal(STRING_CONSTANT_PREFIX + value, IrType.Bytes);

	/** The name of each global by index (`HlCode.globalNames`): null for a class value, which its object type names. */
	public function globalNames():Array<Null<String>> {
		var names:Array<Null<String>> = [for (_ in 0...globalCount) null];
		for (name => index in globalEntries.indices)
			if (index < globalCount)
				names[index] = name;
		return names;
	}

	/**
	 * Whether the object type named `name` is defined by every module section that uses it rather than owned by one
	 * (`HlSectionWriter`): String, the runtime headers and the anonymous structures, which no declaration owns.
	 */
	public static function isSharedDefinition(name:String):Bool
		return name == "String" || StringTools.startsWith(name, RUNTIME_HEADER_PREFIX)
			|| compiler.semantic.SemanticSignature.isAnonymousName(name);

	static inline final RUNTIME_HEADER_PREFIX = "runtime-header:";

	/** Every named global (the static fields), by name: what a refused patch names a stored closure's holder by. */
	public function namedGlobals():Map<String, Int>
		return [for (name => index in globalEntries.indices) if (index < globalCount) name => index];

	/** The literal globals, in index order, with the literal each one holds; read at once, as later globals can extend it. */
	public function stringConstantGlobals():Array<{global:Int, value:String}> {
		var constants = globalEntries.stringConstants;
		return constants.length == stringConstantCount ? constants : constants.slice(0, stringConstantCount);
	}

	/** Whether this table has the literal globals `other` has, so a module's constants made for one hold for the other. */
	public function sameStringConstants(other:HlSymbolTable):Bool
		return globalEntries == other.globalEntries && stringConstantCount == other.stringConstantCount;

	static function collectStringConstants(globalIndices:Map<String, Int>):Array<{global:Int, value:String}> {
		var result:Array<{global:Int, value:String}> = [];
		for (name => index in globalIndices)
			if (StringTools.startsWith(name, STRING_CONSTANT_PREFIX))
				result.push({global: index, value: name.substr(STRING_CONSTANT_PREFIX.length)});
		result.sort((left, right) -> left.global < right.global ? -1 : left.global > right.global ? 1 : 0);
		return result;
	}

	public function requireGlobalIndex(name:String):Int {
		var index = globalIndex(name);
		if (index == null)
			throw new InternalError('Unknown static field global "$name"');
		return index;
	}

	public function requireObjectMethodIndex(objectName:String, methodName:String):Int {
		if (!objectMethodIndices.exists(objectName))
			throw new InternalError('Unknown IR method "$objectName.$methodName"');
		var methods = objectMethodIndices.get(objectName);
		if (!methods.exists(methodName))
			throw new InternalError('Unknown IR method "$objectName.$methodName"');
		return methods.get(methodName);
	}

	public function requireInterfaceMethodIndex(interfaceName:String, methodName:String):Int {
		if (!interfaceMethodIndices.exists(interfaceName))
			throw new InternalError('Unknown IR method "$interfaceName.$methodName"');
		var methods = interfaceMethodIndices.get(interfaceName);
		if (!methods.exists(methodName))
			throw new InternalError('Unknown IR method "$interfaceName.$methodName"');
		return methods.get(methodName);
	}

	public function internFunction(arguments:Array<IrType>, result:IrType):Int
		return internType(Function(arguments, result));

	function internFunctionByKey(arguments:Array<IrType>, result:IrType, key:String):Int {
		var args = [for (a in arguments) internType(a)],
			ret = internType(result),
			index = types.length;
		types.push(Function(args, ret));
		typeIndices.set(key, index);
		return index;
	}

	public static function typeKey(type:IrType):String
		return switch type {
			case Void: "void";
			case I32: "i32";
			case I64: "i64";
			case Bool: "bool";
			case F32: "f32";
			case F64: "f64";
			case Bytes: "bytes";
			case RawPtr: "raw-pointer";
			case ManagedBytes: "abstract:realtime_bytes";
			case Dyn: "dyn";
			case Nullable(element): 'null:${typeKey(element)}';
			case TypeRef: "type";
			case Array(element): 'array:${typeKey(element)}';
			case Iterator(_): 'abstract:realtime_iterator';
			case Obj(name): 'obj:$name';
			case Abstract(name): 'abstract:$name';
			case Enum(name): 'enum:$name';
			case EnumTag(name): 'enum-tag:$name';
			case Virtual(name): 'virt:$name';
			case Function(arguments,
				result): 'fun(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
		};
}

/**
 * The strings of tables forked from one another (`HlSymbolTable.fork`). A table only appends strings, so the tables share these
 * for good: each sees the first `HlSymbolTable.stringCount`, and an index past it is one it never had. Only the table at the end
 * appends here; any other copies its prefix first (`prefix`), which is how a build retracted or rolled back to an older table
 * leaves alone what the newer ones added.
 */
private class HlStringEntries {
	public final values:Array<String>;
	public final indices:Map<String, Int>;

	/** A copy of a prefix of `values`, given to the modules of tables that long (`HlSymbolTable.stringTable`). */
	public var table:Array<String> = [];

	public function new(values:Array<String>, indices:Map<String, Int>) {
		this.values = values;
		this.indices = indices;
	}

	/** The first `count` strings, apart from the rest. */
	public function prefix(count:Int):HlStringEntries
		return new HlStringEntries(values.slice(0, count),
			[for (value => index in indices) if (index < count) value => index]);
}

/** The globals of forked tables, shared as `HlStringEntries` shares their strings: each table sees its `globalCount`. */
private class HlGlobalEntries {
	/** The type of each global. */
	public final types:Array<Int>;

	/** The named globals by name: the static fields and the constants. */
	public final indices:Map<String, Int>;

	/** The literal globals in index order, so a build reads only these and a patch only the ones past the published globals. */
	public final stringConstants:Array<{global:Int, value:String}>;

	/** A copy of a prefix of `types`, as `HlStringEntries.table`. */
	public var table:Array<Int> = [];

	public function new(types:Array<Int>, indices:Map<String, Int>, stringConstants:Array<{global:Int, value:String}>) {
		this.types = types;
		this.indices = indices;
		this.stringConstants = stringConstants;
	}

	/** The first `count` globals, with the first `constants` literals among them, apart from the rest. */
	public function prefix(count:Int, constants:Int):HlGlobalEntries
		return new HlGlobalEntries(types.slice(0, count),
			[for (name => index in indices) if (index < count) name => index],
			stringConstants.slice(0, constants));
}
