package compiler.ir.analysis;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;
import compiler.ir.reuse.IrFunctionMemo;

/**
 * The fields the contributions name, `Class.field` as the class the receiver's type names and the field, numbered the first time
 * one is named: a contribution keeps numbers, and the whole-program step reads them without making a key. A session's memo keeps
 * one (`IrFieldStoreMemo`), which only grows, as the field names of a program do.
 */
class IrFieldKeys {
	final ids:Map<String, Map<String, Int>> = [];

	/** By key, its class and its field. */
	public final owners:Array<String> = [];

	public final fields:Array<String> = [];

	public function new() {}

	/** The key of field `field` of class `owner`. */
	public function key(owner:String, field:String):Int {
		var byField = ids.get(owner);
		if (byField == null)
			ids.set(owner, byField = []);
		var known = byField.get(field);
		if (known != null)
			return known;
		var made = owners.length;
		byField.set(field, made);
		owners.push(owner);
		fields.push(field);
		return made;
	}

	/** How many keys there are. */
	public inline function count():Int
		return owners.length;

	/** Key `key` as text, `Class.field`: for diagnostics. */
	public inline function text(key:Int):String
		return owners[key] + "." + fields[key];
}

/**
 * What the whole-program step of `IrNonNullFields` reads of each final function, from that function alone (`IrFieldStores`), kept
 * while the function is the same object, with the field keys the contributions name. A session keeps one with its lowered
 * functions (`HlLoweredCache`).
 */
class IrFieldStoreMemo {
	public final keys = new IrFieldKeys();
	public final functions = new IrFunctionMemo<IrFieldStores>();

	public function new() {}
}

/**
 * What the whole-program step of `IrNonNullFields` reads of one function, from it alone: the field stores it makes, the objects it
 * makes and the fields it sets on each before anything else sees it. A function with none of these has `NONE`.
 *
 * Fields are keys (`IrFieldKeys`): the class the receiver's type names and the field, resolved to the declaring class later. A
 * stored value is non-null when its definition says so at a glance (`IrNonNullFields.fresh`); one that is a field read is non-null
 * when that field is.
 */
class IrFieldStores {
	@:processWide("the contribution of a function that stores, makes and reflects nothing, never changed")
	public static final NONE = new IrFieldStores();

	/** The fields it may store null in. */
	public final nullable:Array<Int> = [];

	/** Pairs of a field and the field whose value it stores: non-null when the second is. */
	public final copied:Array<Int> = [];

	/** Field names it writes on a receiver that is no class (dynamic, structural); `*` for any name. */
	public final anyOwner:Array<String> = [];

	/**
	 * Triples of a callee, a receiver class and a field name for its calls that pass a dynamic first argument with another after
	 * it, which a reflective write (`IrNonNullFields.REFLECTIVE_WRITES`) is: the class the argument was converted from, `()`
	 * and the callee when a call returned it (no class's when that makes a dynamic object), or `*` when it cannot be told; the
	 * name when it is a constant string, else `*`.
	 */
	public final dynamicCalls:Array<String> = [];

	/**
	 * The objects it makes, or the receiver it initializes when it is a constructor (`IrObjectInit`), each with what it sets
	 * before the object escapes.
	 */
	public final inits:Array<IrObjectInit> = [];

	public function new() {}

	inline function isEmpty():Bool
		return nullable.length == 0 && copied.length == 0 && anyOwner.length == 0 && dynamicCalls.length == 0
			&& inits.length == 0;

	/** This contribution, or `NONE` when it has nothing. */
	public function settled():IrFieldStores
		return isEmpty() ? NONE : this;

	/** Whether `other` reads the same as this (`--check-reuse`). */
	public function same(other:IrFieldStores):Bool {
		if (!sameInts(nullable, other.nullable) || !sameInts(copied, other.copied)
			|| anyOwner.join("\n") != other.anyOwner.join("\n")
			|| dynamicCalls.join("\n") != other.dynamicCalls.join("\n")
			|| inits.length != other.inits.length)
			return false;
		for (index in 0...inits.length)
			if (!inits[index].same(other.inits[index]))
				return false;
		return true;
	}

	public static function sameInts(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length)
			return false;
		for (index in 0...a.length)
			if (a[index] != b[index])
				return false;
		return true;
	}
}

/**
 * The fields one object is given before anything but its own initialization sees it: on the block that makes it (`NewObject`) or
 * from the entry of its constructor, every field it stores a non-null value in before the first row that reads it or lets it go.
 * A call of a constructor on it is followed: the fields that constructor sets count (`IrNonNullFields`), and when the constructor
 * lets nothing see the object, so do the fields set after the call.
 */
class IrObjectInit {
	/** A set value that is non-null at a glance, rather than a field's (`sources`). */
	public static inline final FRESH = -1;

	/** The class made; for a constructor, the class whose constructor it is. */
	public final type:String;

	/** Whether this is a constructor's own initialization of its receiver rather than an object it makes. */
	public final constructor:Bool;

	/**
	 * The fields set before the constructor call, or before the first escape, then from `after` on those set after that call until
	 * the next escape; each with the key of the field whose value it copies in `sources`, or `FRESH`.
	 */
	public final names:Array<String> = [];

	public final sources:Array<Int> = [];

	/** Where the fields set after the constructor call start in `names`. */
	public var after = -1;

	/** The class whose constructor is called on it, or null. */
	public var called:Null<String> = null;

	/** Whether nothing but its own initialization sees the receiver (for a constructor: in the whole function). */
	public var contained = false;

	public function new(type:String, constructor:Bool) {
		this.type = type;
		this.constructor = constructor;
	}

	/** Records that field `name` is set to a value non-null as `source` (a key, or `FRESH`) is. */
	public inline function set(name:String, source:Int):Void {
		names.push(name);
		sources.push(source);
	}

	/** The end of the fields set before the constructor call. */
	public inline function beforeEnd():Int
		return after < 0 ? names.length : after;

	public function same(other:IrObjectInit):Bool
		return type == other.type && constructor == other.constructor && after == other.after && called == other.called
			&& contained == other.contained && names.join("\n") == other.names.join("\n")
			&& IrFieldStores.sameInts(sources, other.sources);
}

/**
 * The fields of classes that are never null once the object is constructed, proven over the whole final program; the backends
 * drop the null check of a dereference of a value read from one (`IrNonNullFacts`).
 *
 * A field `C.f` holding a reference qualifies when:
 * - every object of `C` or a subclass is made in the program (`NewObject`), and no native makes one (no native returns one);
 * - each of them is given a non-null `f` before anything but its initialization sees it (`IrObjectInit`): the block that makes
 *   it, or the constructors it runs, set `f` before the object is read, passed on or stored; so `f` is never read null, not even
 *   from the constructor (a read in a constructor stops what counts as set before it);
 * - every store of `f` anywhere stores a non-null value: a fresh object, a constant string, a closure, a new array, a method's
 *   receiver, or the value of a field that qualifies (the greatest set that holds);
 * - nothing writes `f` but those stores: no write through a dynamic or structural receiver, nor by reflection, names it, and no
 *   reflective write names a field it cannot see (which rules out every field).
 *
 * What it reads of each function it reads from that function alone (`IrFieldStores`), kept by the session while the function is
 * the same object (`IrFieldStoreMemo`), so a build reads only the functions it made. The step over the program combines them on
 * numbers: each declared field of the program is a slot, and a contribution's keys resolve to slots once per build.
 */
class IrNonNullFields {
	@:processWide("an empty set of fields, only ever read")
	static final NONE:Map<String, Bool> = [];

	/** The value of `resolved` for a key not resolved yet. */
	static inline final UNRESOLVED = -2;

	final functions:Array<IrFunction>;
	final objects:Array<IrObject>;
	final keys:IrFieldKeys;

	/** By object name, its index in `objects`. */
	final indices:Map<String, Int> = [];

	/** By object index, the index of its base, or -1. */
	final bases:Array<Int> = [];

	/** By object index, its first slot: the slots of its fields, in order, are `slots[object] ...`. */
	final slots:Array<Int> = [];

	/** By slot, whether the field may still be never null (the greatest set that holds, once solved). */
	final candidates:Array<Bool> = [];

	/** By key, the slot of the field it names as declared, -1 when no class declares it, or `UNRESOLVED`. */
	final resolved:Array<Int> = [];

	/** By class, the fields known non-null on a receiver of that type, as asked for. */
	final known:Map<String, Map<String, Bool>> = [];

	/**
	 * The table for `program`'s final functions and objects, kept on it while they are the same arrays. `memo` keeps the
	 * contributions for later builds; with `checks` (`--check-reuse`), each one it reuses is read again and compared.
	 */
	public static function of(program:IrProgram, ?memo:IrFieldStoreMemo, checks = false):IrNonNullFields {
		var table = program.nonNullFields;
		if (table == null || table.functions != program.functions || table.objects != program.objects) {
			table = new IrNonNullFields(program, memo != null ? memo : new IrFieldStoreMemo(), checks);
			program.nonNullFields = table;
		}
		return table;
	}

	/** The fields known non-null on a receiver of class `type`; empty for any other type. */
	public function fieldsOf(type:String):Map<String, Bool> {
		var fields = known.get(type);
		if (fields != null)
			return fields;
		var index = indices.get(type), depth = 0, found:Null<Map<String, Bool>> = null;
		while (index != null && index >= 0 && depth++ < 256) {
			var object = objects[index], slot = slots[index];
			for (field in object.fields) {
				if (candidates[slot++]) {
					if (found == null)
						found = [];
					found.set(field.name, true);
				}
			}
			index = bases[index];
		}
		var result = found != null ? found : NONE;
		known.set(type, result);
		return result;
	}

	/** `fieldsOf(type)` as text, sorted: what a lowering that read it records. */
	public function describe(type:String):String {
		var names = [for (name in fieldsOf(type).keys()) name];
		names.sort(Reflect.compare);
		return names.join(",");
	}

	function new(program:IrProgram, memo:IrFieldStoreMemo, checks:Bool) {
		functions = program.functions;
		objects = program.objects;
		keys = memo.keys;
		// The subclasses of each class by its name, which need not be an object of the program.
		var children:Map<String, Array<Int>> = [], slotCount = 0;
		for (index in 0...objects.length) {
			var object = objects[index], base = object.base;
			indices.set(object.name, index);
			slots.push(slotCount);
			slotCount += object.fields.length;
			if (base != null) {
				var list = children.get(base);
				if (list == null)
					children.set(base, list = []);
				list.push(index);
			}
		}
		for (object in objects) {
			var base = object.base, parent = base == null ? null : indices.get(base);
			bases.push(parent == null ? -1 : parent);
		}
		var byName:Map<String, IrObject> = [for (object in objects) object.name => object];
		var stores = [for (fn in functions) storesOf(fn, byName, memo, checks)];
		memo.functions.endBuild();
		for (_ in 0...slotCount)
			candidates.push(false);
		for (_ in 0...keys.count())
			resolved.push(UNRESOLVED);
		// Any field name written where its owner cannot be told, and the classes something other than the program makes.
		var anyOwner:Map<String, Bool> = [], reflective:Map<String, Bool> = [], dynamicObjects:Map<String, Bool> = [];
		for (native in program.natives) {
			if (REFLECTIVE_WRITES.exists(native.symbol))
				reflective.set(native.name, true);
			if (native.symbol == DYNAMIC_OBJECT)
				dynamicObjects.set(native.name, true);
		}
		// Reflective writes on a receiver of a known class, by class: the names they write, `*` for any.
		var written:Array<String> = [];
		for (list in stores) {
			for (name in list.anyOwner)
				anyOwner.set(name, true);
			var index = 0;
			while (index < list.dynamicCalls.length) {
				if (reflective.exists(list.dynamicCalls[index])) {
					var owner = list.dynamicCalls[index + 1], name = list.dynamicCalls[index + 2];
					// A dynamic object a call made is no class's.
					if (StringTools.startsWith(owner, "()"))
						owner = dynamicObjects.exists(owner.substr(2)) ? "" : "*";
					if (owner == "*")
						anyOwner.set(name, true);
					else if (owner != "") {
						written.push(owner);
						written.push(name);
					}
				}
				index += 3;
			}
		}
		if (anyOwner.exists("*"))
			return;
		// The classes something other than the program makes, and their subclasses.
		var foreign = [for (_ in 0...objects.length) false];
		function made(type:IrType)
			switch type {
				case Obj(name):
					var start = indices.get(name), direct = children.get(name);
					if (start != null)
						foreign[start] = true;
					var pending = direct == null ? [] : direct.copy();
					while (pending.length > 0) {
						var next = pending.pop();
						if (foreign[next])
							continue;
						foreign[next] = true;
						var list = children.get(objects[next].name);
						if (list != null)
							for (child in list)
								pending.push(child);
					}
				default:
			}
		for (native in program.natives)
			made(native.result);
		for (native in program.cNatives)
			made(native.result);
		// Candidates: the reference fields of classes the program alone makes.
		for (index in 0...objects.length) {
			var object = objects[index];
			if (!object.isValue && object.nativeLayout == null && !foreign[index]) {
				var slot = slots[index];
				for (field in object.fields)
					candidates[slot++] = isReference(field.type) && !anyOwner.exists(field.name);
			}
		}
		for (list in stores)
			for (key in list.nullable) {
				var slot = resolve(key);
				if (slot >= 0)
					candidates[slot] = false;
			}
		// A reflective write reaches the fields of its receiver's class, its bases and, for an object of a subclass, theirs.
		var index = 0;
		while (index < written.length) {
			var name = written[index + 1], pending = [written[index]], depth = 0;
			while (pending.length > 0 && depth++ < 100000) {
				var type = pending.pop(), start = indices.get(type), owner = start == null ? -1 : start, hops = 0;
				while (owner >= 0 && hops++ < 256) {
					var slot = slots[owner];
					for (field in objects[owner].fields) {
						if (name == "*" || field.name == name)
							candidates[slot] = false;
						slot++;
					}
					owner = bases[owner];
				}
				var list = children.get(type);
				if (list != null)
					for (child in list)
						pending.push(objects[child].name);
			}
			index += 2;
		}
		// The constructors, by class, for the objects that run one; the objects made, by class.
		var constructors:Map<String, IrObjectInit> = [],
			sites:Array<Null<Array<IrObjectInit>>> = [for (_ in 0...objects.length) null];
		for (list in stores)
			for (init in list.inits)
				if (init.constructor)
					constructors.set(init.type, init);
				else {
					var type = indices.get(init.type);
					if (type != null) {
						var known = sites[type];
						if (known == null)
							sites[type] = known = [];
						known.push(init);
					}
				}
		// The greatest set that holds: drop what a store or an object's initialization disproves until nothing changes.
		var changed = true;
		while (changed) {
			changed = false;
			for (list in stores) {
				var index = 0, copied = list.copied;
				while (index < copied.length) {
					var field = resolve(copied[index]);
					if (field >= 0 && candidates[field]) {
						var source = resolve(copied[index + 1]);
						if (source < 0 || !candidates[source]) {
							candidates[field] = false;
							changed = true;
						}
					}
					index += 2;
				}
			}
			for (type in 0...objects.length) {
				var made = sites[type];
				if (foreign[type] || made == null)
					continue;
				// Each base's fields must be set on every object of this class.
				var owner = type, depth = 0;
				while (owner >= 0 && depth++ < 256) {
					var slot = slots[owner];
					for (field in objects[owner].fields) {
						if (candidates[slot])
							for (site in made)
								if (!sets(site, field.name, constructors, 0)) {
									candidates[slot] = false;
									changed = true;
									break;
								}
						slot++;
					}
					owner = bases[owner];
				}
			}
		}
	}

	/** The slot of the field `key` names, as declared by its class or a base; -1 when none declares it. */
	function resolve(key:Int):Int {
		var known = resolved[key];
		if (known != UNRESOLVED)
			return known;
		var field = keys.fields[key], index = indices.get(keys.owners[key]), depth = 0, found = -1;
		while (found < 0 && index != null && index >= 0 && depth++ < 256) {
			var slot = slots[index];
			for (declared in objects[index].fields) {
				if (declared.name == field) {
					found = slot;
					break;
				}
				slot++;
			}
			index = bases[index];
		}
		resolved[key] = found;
		return found;
	}

	/** Whether `init` sets field `name` to a value non-null as the candidates stand. */
	function sets(init:IrObjectInit, name:String, constructors:Map<String, IrObjectInit>, depth:Int):Bool {
		if (setIn(init, 0, init.beforeEnd(), name))
			return true;
		var called = init.called;
		if (called == null || depth > 64)
			return false;
		var constructor = constructors.get(called);
		if (constructor == null)
			return false;
		return sets(constructor, name, constructors, depth + 1)
			|| contains(constructor, constructors, depth + 1) && setIn(init, init.beforeEnd(), init.names.length, name);
	}

	/** Whether nothing but `init` and the constructors it calls see the object. */
	static function contains(init:IrObjectInit, constructors:Map<String, IrObjectInit>, depth:Int):Bool {
		if (!init.contained || depth > 64)
			return false;
		var called = init.called;
		if (called == null)
			return true;
		var constructor = constructors.get(called);
		return constructor != null && contains(constructor, constructors, depth + 1);
	}

	/** Whether the fields `init` sets from `start` to `end` set `name` to a value non-null as the candidates stand. */
	function setIn(init:IrObjectInit, start:Int, end:Int, name:String):Bool {
		for (index in start...end)
			if (init.names[index] == name) {
				var source = init.sources[index];
				if (source == IrObjectInit.FRESH)
					return true;
				var field = resolve(source);
				if (field >= 0 && candidates[field])
					return true;
			}
		return false;
	}

	/**
	 * The contribution of `fn`: the one `memo` keeps for it, or one read now and kept. With `checks`, one kept is read again
	 * and must be the same.
	 */
	static function storesOf(fn:IrFunction, objects:Map<String, IrObject>, memo:IrFieldStoreMemo,
			checks:Bool):IrFieldStores {
		var known = memo.functions.get(fn);
		if (known != null) {
			if (checks && !read(fn, objects, memo.keys).same(known))
				throw new InternalError('--check-reuse: the field stores kept for ${fn.name} differ from its body');
			return known;
		}
		var made = read(fn, objects, memo.keys);
		memo.functions.set(fn, made);
		return made;
	}

	static function read(fn:IrFunction, objects:Map<String, IrObject>, keys:IrFieldKeys):IrFieldStores {
		var made = new IrFieldStores(),
			known = fn.body,
			body = known != null ? known : compiler.ir.model.IrBodyBuilder.encode(fn,
				compiler.ir.model.IrTypeIds.ofFunctions([fn]));
		var receiver = IrValueId.of(-1);
		var receiverClass = IrNonNullFacts.receiverClass(body);
		if (receiverClass != null && IrNonNullFacts.isMethodReceiver(body, objects.get(receiverClass)))
			receiver = body.argument(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), tries = false;
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.BeginTry:
						tries = true;
					case IrOpcode.FieldSet:
						var name = body.symbol(row).name;
						switch body.valueType(body.operand(row, 0)) {
							case Obj(type):
								var value = body.operand(row, 1);
								if (isReference(body.valueType(value))) {
									var source = fresh(body, value, receiver, keys);
									if (source == NOT_FRESH)
										made.nullable.push(keys.key(type, name));
									else if (source != IrObjectInit.FRESH) {
										made.copied.push(keys.key(type, name));
										made.copied.push(source);
									}
								}
							default:
								made.anyOwner.push(name);
						}
					case IrOpcode.Call:
						if (body.operandCount(row) >= 2)
							switch body.valueType(body.operand(row, 0)) {
								case Dyn:
									dynamicCall(body, row, made);
								default:
							}
					case IrOpcode.NewObject:
						// One made inside a try region counts with nothing set: the handler could see it at any point.
						var type = body.symbol(row).name, object = objects.get(type);
						if (object != null && !object.isValue)
							made.inits.push(tries ? new IrObjectInit(type, false) : initOf(body, block, row,
								body.output(row), type, false, receiver, keys));
					default:
				}
				row = body.nextRow(row);
			}
		}
		if (receiver.exists() && body.name == receiverClass + ".new")
			made.inits.push(initOf(body, 0, -1, receiver, receiverClass, true, receiver, keys));
		return made.settled();
	}

	/** The symbol of the runtime native that makes a dynamic object, which no class's field is. */
	static inline final DYNAMIC_OBJECT = "__reflect_dynamic_object";

	/** The symbols of the runtime natives that write an object's field by name. */
	@:processWide("a constant table of the natives that write a field by name, only ever read")
	static final REFLECTIVE_WRITES:Map<String, Bool> = [
		"__reflect_set_field" => true,
		"__reflect_delete_field" => true,
		"__reflect_object_set_field" => true
	];

	/** A call that could be a reflective write (`IrFieldStores.dynamicCalls`). */
	static function dynamicCall(body:IrBody, row:Int, made:IrFieldStores):Void {
		var target = body.definingRow(body.operand(row, 0)), owner = "*";
		if (target >= 0)
			switch body.opcode(target) {
				case IrOpcode.Call:
					owner = "()" + body.symbol(target).name;
				case IrOpcode.ToDyn:
					switch body.valueType(body.operand(target, 0)) {
						case Obj(type):
							owner = type;
						default:
					}
				default:
			}
		var name = body.definingRow(body.operand(row, 1));
		made.dynamicCalls.push(body.symbol(row).name);
		made.dynamicCalls.push(owner);
		made.dynamicCalls.push(name >= 0 && body.opcode(name) == IrOpcode.ConstString ? body.string(name) : "*");
	}

	/**
	 * What `object` is set to from row `from` of block `block` on (from its first row when -1), up to the first row that reads it,
	 * lets it go or begins a try (whose handler could see it); the constructor called on it is followed, and so are the rows after
	 * that call.
	 */
	static function initOf(body:IrBody, block:Int, from:Int, object:IrValueId, type:String, constructor:Bool,
			receiver:IrValueId, keys:IrFieldKeys):IrObjectInit {
		var init = new IrObjectInit(type, constructor),
			aliases:Array<Int> = [object],
			row = from < 0 ? body.firstRow(block) : body.nextRow(from),
			escaped = false;
		while (row >= 0 && !escaped && !body.opcode(row).isTerminator()) {
			var opcode = body.opcode(row), subject = opcode == IrOpcode.BeginTry;
			for (index in 0...body.operandCount(row))
				if (aliases.indexOf(body.operand(row, index)) >= 0)
					subject = true;
			if (subject)
				switch opcode {
					case IrOpcode.FieldSet if (aliases.indexOf(body.operand(row, 0)) >= 0
						&& aliases.indexOf(body.operand(row, 1)) < 0):
						var source = fresh(body, body.operand(row, 1), receiver, keys);
						if (source != NOT_FRESH)
							init.set(body.symbol(row).name, source);
					case IrOpcode.Upcast:
						aliases.push(body.output(row));
					case IrOpcode.Call if (init.called == null && aliases.indexOf(body.operand(row, 0)) >= 0
						&& isConstructor(body.symbol(row).name) && !passedAgain(body, row, aliases)):
						var name = body.symbol(row).name;
						init.called = name.substr(0, name.length - CONSTRUCTOR.length);
						init.after = init.names.length;
					default:
						escaped = true;
				}
			if (!escaped)
				row = body.nextRow(row);
		}
		// A constructor contains its receiver when the scan reached its entry block's terminator, which does not read it, and no
		// other block reads it either.
		if (constructor && !escaped && row >= 0) {
			var read = false;
			for (index in 0...body.operandCount(row))
				if (aliases.indexOf(body.operand(row, index)) >= 0)
					read = true;
			init.contained = !read && !usedAfter(body, block, aliases);
		}
		return init;
	}

	/** Whether the call at `row` passes one of `aliases` again after its first argument. */
	static function passedAgain(body:IrBody, row:Int, aliases:Array<Int>):Bool {
		for (index in 1...body.operandCount(row))
			if (aliases.indexOf(body.operand(row, index)) >= 0)
				return true;
		return false;
	}

	/** Whether a row of a block other than `block` reads one of `values`. */
	static function usedAfter(body:IrBody, block:Int, values:Array<Int>):Bool {
		for (other in 0...body.blockCount())
			if (other != block) {
				var row = body.firstRow(other);
				while (row >= 0) {
					for (index in 0...body.operandCount(row))
						if (values.indexOf(body.operand(row, index)) >= 0)
							return true;
					row = body.nextRow(row);
				}
			}
		return false;
	}

	static inline final CONSTRUCTOR = ".new";

	static inline function isConstructor(name:String):Bool
		return StringTools.endsWith(name, CONSTRUCTOR);

	/** What `fresh` gives for a value it cannot tell non-null. */
	static inline final NOT_FRESH = -2;

	/**
	 * Whether `value` is non-null at a glance: `IrObjectInit.FRESH` when it is (a fresh object, a constant string, a closure, a new
	 * array, a method's receiver), the key of the field it reads when it is a field's value, `NOT_FRESH` when neither tells.
	 */
	static function fresh(body:IrBody, value:IrValueId, receiver:IrValueId, keys:IrFieldKeys):Int {
		var depth = 0;
		while (depth++ < 16) {
			if (value == receiver)
				return IrObjectInit.FRESH;
			var row = body.definingRow(value);
			if (row < 0)
				return NOT_FRESH;
			switch body.opcode(row) {
				case IrOpcode.NewObject, IrOpcode.ConstString, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
					return IrObjectInit.FRESH;
				case IrOpcode.Upcast, IrOpcode.SafeCast:
					value = body.operand(row, 0);
				case IrOpcode.Call if (StringTools.startsWith(body.symbol(row).name, "__array_alloc_")):
					return IrObjectInit.FRESH;
				case IrOpcode.FieldGet:
					return switch body.valueType(body.operand(row, 0)) {
						case Obj(type): keys.key(type, body.symbol(row).name);
						default: NOT_FRESH;
					};
				default:
					return NOT_FRESH;
			}
		}
		return NOT_FRESH;
	}

	static function isReference(type:IrType):Bool
		return switch type {
			case Obj(_), Array(_), Virtual(_), Function(_, _), Enum(_), Bytes, Dyn: true;
			default: false;
		};
}
