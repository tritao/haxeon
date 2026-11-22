package compiler.hl.lower;

import compiler.ir.Ir.IrObject;

/**
 * The facts lowering reads about entities other than the function it lowers, numbered, with a print per fact that changes exactly
 * when the fact's answer does and is never given twice, so a lowered function that recorded a fact at a print still holds while the
 * fact has it. A fact is worked out at most once per lowering (`begin`). The session keeps one with the lowered functions
 * (`HlLoweredCache`), which the copies of that cache share: a rolled-back build can only make a print newer, never reuse one.
 *
 * An object fact keeps its print while the program's object of that name compares the same, part by part (`sameObject`), as the
 * one the print was last made for: an `IrObject` is never changed once made, and the stages make new ones every build. Under
 * `--check-reuse` the two objects' texts are compared too, so a part `sameObject` does not know of is caught.
 */
class HlFactPrints {
	final ids:Map<String, Int> = [];
	final names:Array<String> = [];
	final isObject:Array<Bool> = [];
	final answers:Array<String> = [];
	final objects:Array<Null<IrObject>> = [];
	final prints:Array<Int> = [];
	final worked:Array<Int> = [];

	var lowering = 0;
	var lastPrint = 0;

	/** Compare the texts of two objects `sameObject` finds the same, and fail if they differ. */
	public var checkObjects = false;

	public function new() {}

	/** Starts a lowering: each fact is worked out again when next asked. */
	public function begin():Void
		lowering++;

	public function objectFact(name:String):Int
		return id("object:" + name, name, true);

	public function typedFact(name:String):Int
		return id("typed:" + name, name, false);

	function id(key:String, name:String, object:Bool):Int {
		var known = ids.get(key);
		if (known != null)
			return known;
		var made = names.length;
		ids.set(key, made);
		names.push(name);
		isObject.push(object);
		answers.push(null);
		objects.push(null);
		prints.push(0);
		worked.push(0);
		return made;
	}

	/** The print of fact `id` in this lowering, `view` being what it reads. */
	public function print(id:Int, view:HlLoweringView):Int {
		if (worked[id] == lowering)
			return prints[id];
		worked[id] = lowering;
		if (isObject[id]) {
			var found = view.currentObject(names[id]), last = objects[id];
			var same = prints[id] != 0 && (found == last || found != null && last != null && sameObject(found, last));
			if (same && checkObjects && found != last && Std.string(found) != Std.string(last))
				throw new compiler.core
					.InternalError('--check-reuse: object ${names[id]} compares the same as the one lowering read, but is not');
			objects[id] = found;
			if (!same)
				prints[id] = ++lastPrint;
			return prints[id];
		}
		var key = view.currentTypedKey(names[id]), answer = key == null ? "-" : key;
		if (prints[id] == 0 || answer != answers[id]) {
			answers[id] = answer;
			prints[id] = ++lastPrint;
		}
		return prints[id];
	}

	/** Whether two objects of the same name read the same to lowering: every part of an `IrObject`. */
	static function sameObject(a:IrObject, b:IrObject):Bool {
		if (a.isValue != b.isValue || a.base != b.base || !sameNativeLayout(a.nativeLayout, b.nativeLayout)
			|| a.interfaces.length != b.interfaces.length || a.fields.length != b.fields.length
			|| a.methods.length != b.methods.length)
			return false;
		for (index in 0...a.interfaces.length)
			if (a.interfaces[index] != b.interfaces[index])
				return false;
		for (index in 0...a.fields.length) {
			var left = a.fields[index], right = b.fields[index];
			if (left.name != right.name || !compiler.ir.IrTypeIdentity.same(left.type, right.type)
				|| !sameFieldLayout(left.nativeLayout, right.nativeLayout)
				|| !sameStorage(left.scalarStorage, right.scalarStorage)
				|| !sameStorage(left.nullableScalarStorage, right.nullableScalarStorage))
				return false;
		}
		for (index in 0...a.methods.length) {
			var left = a.methods[index], right = b.methods[index];
			if (left.name != right.name || left.functionName != right.functionName)
				return false;
		}
		return true;
	}

	static function sameNativeLayout(a:Null<compiler.ir.Ir.IrObjectNativeLayout>,
			b:Null<compiler.ir.Ir.IrObjectNativeLayout>):Bool
		return a == null ? b == null : b != null && a.target == b.target && a.size == b.size
			&& a.alignment == b.alignment;

	static function sameFieldLayout(a:Null<compiler.ir.Ir.IrObjectFieldNativeLayout>,
			b:Null<compiler.ir.Ir.IrObjectFieldNativeLayout>):Bool
		return a == null ? b == null : b != null && a.offset == b.offset && a.size == b.size
			&& a.alignment == b.alignment && a.signed == b.signed && a.inlineRecord == b.inlineRecord;

	static function sameStorage(a:Null<compiler.ir.Ir.IrScalarStorage>, b:Null<compiler.ir.Ir.IrScalarStorage>):Bool
		return a == null ? b == null : b != null && a.size == b.size && a.signed == b.signed;

	public function describe(id:Int):String
		return (isObject[id] ? "object:" : "typed:") + names[id];
}

/**
 * The only way lowering a function sees an entity other than that function: an object type (its fields, base, methods and value
 * layout) or the typed-interface key of a dispatch function. Every read is recorded as a fact with its print (`HlFactPrints`), so a
 * lowered function carries the exact list of outside facts it depends on, and a later build can ask whether they still hold before it
 * keeps the function. Lowering holds neither the program nor the object table, so a fact cannot be read without being recorded.
 */
class HlLoweringView {
	final objects:Map<String, IrObject>;
	final typedKeys:Map<String, String>;
	final prints:HlFactPrints;
	var reads:Null<Array<Int>>;
	var readMarks:Map<Int, Bool> = [];

	/**
	 * A view over `objects` as they are filled in (lowering) or as they stand (a pass asking what lowering would see), numbering its
	 * facts with `prints` (the session's, or its own).
	 */
	public function new(typedKeys:Map<String, String>, ?objects:Map<String, IrObject>, ?prints:HlFactPrints) {
		this.typedKeys = typedKeys;
		this.objects = objects == null ? [] : objects;
		this.prints = prints == null ? new HlFactPrints() : prints;
		this.prints.begin();
	}

	/** Makes `object` known: metadata lowering does this while it orders object types, before any fact is read. */
	public function define(object:IrObject):Void
		objects.set(object.name, object);

	public function beginFunction():Void {
		reads = [];
		readMarks = [];
	}

	/** The facts read since `beginFunction`, as pairs of a fact and its print. */
	public function endFunction():Array<Int> {
		var facts = reads == null ? [] : reads;
		reads = null;
		return facts;
	}

	function read(id:Int):Void
		if (reads != null && !readMarks.exists(id)) {
			readMarks.set(id, true);
			reads.push(id);
			reads.push(prints.print(id, this));
		}

	public function object(name:String):Null<IrObject> {
		if (reads != null)
			read(prints.objectFact(name));
		return objects.get(name);
	}

	public function hasObject(name:String):Bool
		return object(name) != null;

	/** The key under which dispatch function `name` registers its method table, or null for any other function. */
	public function typedInterfaceKey(name:String):Null<String> {
		if (reads != null)
			read(prints.typedFact(name));
		return typedKeys.get(name);
	}

	/** The object named `name` as this view has it, unrecorded: for `HlFactPrints` only. */
	public inline function currentObject(name:String):Null<IrObject>
		return objects.get(name);

	/** The typed-interface key of `name` as this view has it, unrecorded: for `HlFactPrints` only. */
	public inline function currentTypedKey(name:String):Null<String>
		return typedKeys.get(name);

	/** Null when every fact of `facts` (pairs of a fact and a print) still has its print, else the first that does not. */
	public function holds(facts:Array<Int>):Null<String> {
		var index = 0;
		while (index < facts.length) {
			if (prints.print(facts[index], this) != facts[index + 1])
				return prints.describe(facts[index]);
			index += 2;
		}
		return null;
	}
}
