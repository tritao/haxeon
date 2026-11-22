package compiler.ir.analysis;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;
import compiler.ir.reuse.IrFunctionMemo;

/**
 * What the whole-program step of `IrNonNullFields` reads of one function, from it alone: the field stores it makes, the objects it
 * makes and the fields it sets on each before anything else sees it.
 *
 * Fields are named by the class the receiver's type names and the field, `Class.field`, resolved to the declaring class later.
 * A stored value is non-null when its definition says so at a glance (`IrNonNullFields.freshValue`); one that is a field read
 * is non-null when that field is.
 */
class IrFieldStores {
	/** The fields it may store null in. */
	public final nullable:Array<String> = [];

	/** Pairs of a field and the field whose value it stores: non-null when the second is. */
	public final copied:Array<String> = [];

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
}

/**
 * The fields one object is given before anything but its own initialization sees it: on the block that makes it (`NewObject`) or
 * from the entry of its constructor, every field it stores a non-null value in before the first row that reads it or lets it go.
 * A call of a constructor on it is followed: the fields that constructor sets count (`IrNonNullFields`), and when the constructor
 * lets nothing see the object, so do the fields set after the call.
 */
class IrObjectInit {
	/** The class made; for a constructor, the class whose constructor it is. */
	public final type:String;

	/** Whether this is a constructor's own initialization of its receiver rather than an object it makes. */
	public final constructor:Bool;

	/** The fields set before the constructor call, or before the first escape; each with the field whose value it copies, or "". */
	public final before:Array<String> = [];

	/** The constructor called on it, or null; and the fields set after that call until the next escape, as in `before`. */
	public var called:Null<String> = null;

	public final after:Array<String> = [];

	/** Whether nothing but its own initialization sees the receiver (for a constructor: in the whole function). */
	public var contained = false;

	public function new(type:String, constructor:Bool) {
		this.type = type;
		this.constructor = constructor;
	}
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
 */
class IrNonNullFields {
	@:processWide("an empty set of fields, only ever read")
	static final NONE:Map<String, Bool> = [];

	/** By class, the fields known non-null on a receiver of that type, declared by it or a base. */
	final known:Map<String, Map<String, Bool>> = [];

	final functions:Array<IrFunction>;
	final objects:Array<IrObject>;

	/** The table for `program`'s final functions and objects, kept on it while they are the same arrays. */
	public static function of(program:IrProgram, ?memo:IrFunctionMemo<IrFieldStores>):IrNonNullFields {
		var table = program.nonNullFields;
		if (table == null || table.functions != program.functions || table.objects != program.objects) {
			table = new IrNonNullFields(program, memo != null ? memo : new IrFunctionMemo());
			program.nonNullFields = table;
		}
		return table;
	}

	/** The fields known non-null on a receiver of class `type`; empty for any other type. */
	public function fieldsOf(type:String):Map<String, Bool> {
		var fields = known.get(type);
		return fields != null ? fields : NONE;
	}

	/** `fieldsOf(type)` as text, sorted: what a lowering that read it records. */
	public function describe(type:String):String {
		var names = [for (name in fieldsOf(type).keys()) name];
		names.sort(Reflect.compare);
		return names.join(",");
	}

	function new(program:IrProgram, memo:IrFunctionMemo<IrFieldStores>) {
		functions = program.functions;
		objects = program.objects;
		var byName:Map<String, IrObject> = [], children:Map<String, Array<String>> = [];
		for (object in objects) {
			byName.set(object.name, object);
			if (object.base != null) {
				var list = children.get(object.base);
				if (list == null)
					children.set(object.base, list = []);
				list.push(object.name);
			}
		}
		var stores = [for (fn in functions) storesOf(fn, byName, memo)];
		memo.endBuild();
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
		var foreign:Map<String, Bool> = [];
		function made(type:IrType)
			switch type {
				case Obj(name):
					var pending = [name];
					while (pending.length > 0) {
						var next = pending.pop();
						if (foreign.exists(next))
							continue;
						foreign.set(next, true);
						var list = children.get(next);
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
		// Candidates: the reference fields of classes the program alone makes, as `Declaring.field`.
		var candidates:Map<String, Bool> = [];
		for (object in objects)
			if (!object.isValue && object.nativeLayout == null && !foreign.exists(object.name))
				for (field in object.fields)
					if (isReference(field.type) && !anyOwner.exists(field.name))
						candidates.set(object.name + "." + field.name, true);
		function declaring(type:String, field:String):Null<String> {
			var object = byName.get(type), depth = 0;
			while (object != null && depth++ < 256) {
				for (declared in object.fields)
					if (declared.name == field)
						return object.name + "." + field;
				object = object.base == null ? null : byName.get(object.base);
			}
			return null;
		}
		function resolve(key:String):Null<String> {
			var dot = key.lastIndexOf(".");
			return declaring(key.substr(0, dot), key.substr(dot + 1));
		}
		for (list in stores)
			for (key in list.nullable) {
				var field = resolve(key);
				if (field != null)
					candidates.remove(field);
			}
		// A reflective write reaches the fields of its receiver's class, its bases and, for an object of a subclass, theirs.
		var index = 0;
		while (index < written.length) {
			var name = written[index + 1], pending = [written[index]], depth = 0;
			while (pending.length > 0 && depth++ < 100000) {
				var type = pending.pop(), owner = byName.get(type), hops = 0;
				while (owner != null && hops++ < 256) {
					for (field in owner.fields)
						if (name == "*" || field.name == name)
							candidates.remove(owner.name + "." + field.name);
					owner = owner.base == null ? null : byName.get(owner.base);
				}
				var list = children.get(type);
				if (list != null)
					for (child in list)
						pending.push(child);
			}
			index += 2;
		}
		// The constructors, by name, for the objects that run one.
		var constructors:Map<String, IrObjectInit> = [];
		for (list in stores)
			for (init in list.inits)
				if (init.constructor)
					constructors.set(init.type + ".new", init);
		var sites:Map<String, Array<IrObjectInit>> = [];
		for (list in stores)
			for (init in list.inits)
				if (!init.constructor) {
					var known = sites.get(init.type);
					if (known == null)
						sites.set(init.type, known = []);
					known.push(init);
				}
		// The greatest set that holds: drop what a store or an object's initialization disproves until nothing changes.
		var changed = true;
		while (changed) {
			changed = false;
			for (list in stores) {
				var index = 0;
				while (index < list.copied.length) {
					var field = resolve(list.copied[index]), source = resolve(list.copied[index + 1]);
					if (field != null && candidates.exists(field) && (source == null || !candidates.exists(source))) {
						candidates.remove(field);
						changed = true;
					}
					index += 2;
				}
			}
			for (object in objects) {
				if (foreign.exists(object.name))
					continue;
				var made = sites.get(object.name);
				if (made == null)
					continue;
				// Each base's fields must be set on every object of this class.
				var owner:Null<IrObject> = object, depth = 0;
				while (owner != null && depth++ < 256) {
					for (field in owner.fields) {
						var key = owner.name + "." + field.name;
						if (!candidates.exists(key))
							continue;
						for (site in made)
							if (!sets(site, field.name, key, candidates, constructors, resolve, 0)) {
								candidates.remove(key);
								changed = true;
								break;
							}
					}
					owner = owner.base == null ? null : byName.get(owner.base);
				}
			}
		}
		for (object in objects) {
			var fields:Map<String, Bool> = [], owner:Null<IrObject> = object, depth = 0, any = false;
			while (owner != null && depth++ < 256) {
				for (field in owner.fields)
					if (candidates.exists(owner.name + "." + field.name)) {
						fields.set(field.name, true);
						any = true;
					}
				owner = owner.base == null ? null : byName.get(owner.base);
			}
			if (any)
				known.set(object.name, fields);
		}
	}

	/** Whether `init` sets field `name` (`key` once declared) to a value non-null as `candidates` stand. */
	static function sets(init:IrObjectInit, name:String, key:String, candidates:Map<String, Bool>,
			constructors:Map<String, IrObjectInit>, resolve:String->Null<String>, depth:Int):Bool {
		if (setIn(init.before, name, candidates, resolve))
			return true;
		var called = init.called;
		if (called == null || depth > 64)
			return false;
		var constructor = constructors.get(called);
		if (constructor == null)
			return false;
		return sets(constructor, name, key, candidates, constructors, resolve, depth + 1)
			|| contains(constructor, constructors, depth + 1) && setIn(init.after, name, candidates, resolve);
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

	/** Whether the pairs of `list` set `name` to a value non-null as `candidates` stand. */
	static function setIn(list:Array<String>, name:String, candidates:Map<String, Bool>,
			resolve:String->Null<String>):Bool {
		var index = 0;
		while (index < list.length) {
			if (list[index] == name) {
				var source = list[index + 1];
				if (source == "")
					return true;
				var field = resolve(source);
				if (field != null && candidates.exists(field))
					return true;
			}
			index += 2;
		}
		return false;
	}

	static function storesOf(fn:IrFunction, objects:Map<String, IrObject>,
			memo:IrFunctionMemo<IrFieldStores>):IrFieldStores {
		var known = memo.get(fn);
		if (known != null)
			return known;
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
									var source = fresh(body, value, receiver);
									if (source == null)
										made.nullable.push(type + "." + name);
									else if (source != "") {
										made.copied.push(type + "." + name);
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
								body.output(row),
								type, false, receiver));
					default:
				}
				row = body.nextRow(row);
			}
		}
		if (receiver.exists() && body.name == receiverClass + ".new")
			made.inits.push(initOf(body, 0, -1, receiver, receiverClass, true, receiver));
		// The final bodies outlive this step in a session, which keeps no analysis of them.
		IrBodyAnalysis.release(body);
		memo.set(fn, made);
		return made;
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
			receiver:IrValueId):IrObjectInit {
		var init = new IrObjectInit(type, constructor),
			aliases:Array<Int> = [object],
			list = init.before,
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
						var source = fresh(body, body.operand(row, 1), receiver);
						if (source != null) {
							list.push(body.symbol(row).name);
							list.push(source);
						}
					case IrOpcode.Upcast:
						aliases.push(body.output(row));
					case IrOpcode.Call if (init.called == null && aliases.indexOf(body.operand(row, 0)) >= 0
						&& isConstructor(body.symbol(row).name) && !passedAgain(body, row, aliases)):
						init.called = body.symbol(row).name;
						list = init.after;
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
		var analysis = IrBodyAnalysis.of(body), used = false;
		for (value in values)
			for (index in 0...analysis.useCount(IrValueId.of(value)))
				if (analysis.blockOf(analysis.useRow(IrValueId.of(value), index)) != block)
					used = true;
		return used;
	}

	static inline function isConstructor(name:String):Bool
		return StringTools.endsWith(name, ".new");

	/**
	 * Whether `value` is non-null at a glance: "" when it is (a fresh object, a constant string, a closure, a new array, a method's
	 * receiver), the field it reads as `Class.field` when it is a field's value, null when neither tells.
	 */
	static function fresh(body:IrBody, value:IrValueId, receiver:IrValueId):Null<String> {
		var depth = 0;
		while (depth++ < 16) {
			if (value == receiver)
				return "";
			var row = body.definingRow(value);
			if (row < 0)
				return null;
			switch body.opcode(row) {
				case IrOpcode.NewObject, IrOpcode.ConstString, IrOpcode.StaticClosure, IrOpcode.InstanceClosure:
					return "";
				case IrOpcode.Upcast, IrOpcode.SafeCast:
					value = body.operand(row, 0);
				case IrOpcode.Call if (StringTools.startsWith(body.symbol(row).name, "__array_alloc_")):
					return "";
				case IrOpcode.FieldGet:
					return switch body.valueType(body.operand(row, 0)) {
						case Obj(type): type + "." + body.symbol(row).name;
						default: null;
					};
				default:
					return null;
			}
		}
		return null;
	}

	static function isReference(type:IrType):Bool
		return switch type {
			case Obj(_), Array(_), Virtual(_), Function(_, _), Enum(_), Bytes, Dyn: true;
			default: false;
		};
}
