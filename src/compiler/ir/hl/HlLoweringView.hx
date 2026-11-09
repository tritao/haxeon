package compiler.ir.hl;

import compiler.ir.Ir.IrObject;

/** What lowering read about another entity while it lowered one function, and the answer, as a comparable text. */
typedef HlFact = {
	final key:String;
	final digest:String;
}

/**
 * The only way lowering a function sees an entity other than that function: an object type (its fields, base, methods and value
 * layout) or the typed-interface key of a dispatch function. Every read is recorded with the answer it got, so a lowered function
 * carries the exact list of outside facts it depends on, and a later build can ask whether they still hold before it keeps the
 * function. Lowering holds neither the program nor the object table, so a fact cannot be read without being recorded.
 */
class HlLoweringView {
	final objects:Map<String, IrObject>;
	final typedKeys:Map<String, String>;
	final digests:Map<String, String> = [];
	var reads:Null<Map<String, String>>;

	/** A view over `objects` as they are filled in (lowering) or as they stand (a pass asking what lowering would see). */
	public function new(typedKeys:Map<String, String>, ?objects:Map<String, IrObject>) {
		this.typedKeys = typedKeys;
		this.objects = objects == null ? [] : objects;
	}

	/** Makes `object` known: metadata lowering does this while it orders object types. */
	public function define(object:IrObject):Void {
		objects.set(object.name, object);
		digests.remove(object.name);
	}

	public function beginFunction():Void
		reads = [];

	/** The facts read since `beginFunction`, sorted by key. */
	public function endFunction():Array<HlFact> {
		var facts:Array<HlFact> = [];
		if (reads != null) {
			var keys = [for (key in reads.keys()) key];
			keys.sort(Reflect.compare);
			for (key in keys)
				facts.push({key: key, digest: reads.get(key)});
		}
		reads = null;
		return facts;
	}

	public function object(name:String):Null<IrObject> {
		var found = objects.get(name);
		if (reads != null)
			reads.set("object:" + name, found == null ? "-" : objectDigest(found));
		return found;
	}

	public function hasObject(name:String):Bool
		return object(name) != null;

	/** The key under which dispatch function `name` registers its method table, or null for any other function. */
	public function typedInterfaceKey(name:String):Null<String> {
		var key = typedKeys.get(name);
		if (reads != null)
			reads.set("typed:" + name, key == null ? "-" : key);
		return key;
	}

	/** Whether the facts a lowered function recorded still hold in this view. */
	public function holds(facts:Array<HlFact>):Null<String> {
		for (fact in facts) {
			var current = if (StringTools.startsWith(fact.key, "object:")) {
				var found = objects.get(fact.key.substr(7));
				found == null ? "-" : objectDigest(found);
			} else {
				var key = typedKeys.get(fact.key.substr(6));
				key == null ? "-" : key;
			}
			if (current != fact.digest)
				return fact.key;
		}
		return null;
	}

	function objectDigest(object:IrObject):String {
		var known = digests.get(object.name);
		if (known == null) {
			known = Std.string(object);
			digests.set(object.name, known);
		}
		return known;
	}
}
