package haxeon.agent;

/**
	The one place agentkit touches untyped JSON. Model output and tool arguments
	arrive as JSON text, so this wrapper parses once and exposes typed lookups;
	nothing else in the package handles `Dynamic`.
**/
class JsonObject {
	final value:Dynamic;

	function new(value:Dynamic)
		this.value = value;

	/** Parses a JSON object, or returns null for malformed text and non-object values. */
	public static function parse(text:String):Null<JsonObject> {
		if (text == null)
			return null;
		var parsed:Dynamic = null;
		try
			parsed = haxe.Json.parse(text)
		catch (_:Dynamic)
			return null;
		return isObject(parsed) ? new JsonObject(parsed) : null;
	}

	static function isObject(candidate:Dynamic):Bool
		return candidate != null && !Std.isOfType(candidate, String) && !Std.isOfType(candidate, Array) && !Std.isOfType(candidate, Bool)
			&& !Std.isOfType(candidate, Float) && !Std.isOfType(candidate, Int);

	/** Canonical JSON text for this object. */
	public function toString():String
		return haxe.Json.stringify(value);

	public function has(name:String):Bool
		return Reflect.hasField(value, name) && Reflect.field(value, name) != null;

	public function string(name:String, fallback:String = ""):String {
		var field:Dynamic = Reflect.field(value, name);
		return Std.isOfType(field, String) ? field : fallback;
	}

	public function int(name:String, fallback:Int = 0):Int {
		var field:Dynamic = Reflect.field(value, name);
		return Std.isOfType(field, Int) ? field : Std.isOfType(field, Float) ? Std.int(field) : fallback;
	}

	public function bool(name:String, fallback:Bool = false):Bool {
		var field:Dynamic = Reflect.field(value, name);
		return Std.isOfType(field, Bool) ? field : fallback;
	}

	public function object(name:String):Null<JsonObject> {
		var field:Dynamic = Reflect.field(value, name);
		return isObject(field) ? new JsonObject(field) : null;
	}

	/** Elements that are objects; other elements are skipped. */
	public function objects(name:String):Array<JsonObject> {
		var field:Dynamic = Reflect.field(value, name);
		var result:Array<JsonObject> = [];
		if (Std.isOfType(field, Array)) {
			var items:Array<Dynamic> = field;
			for (item in items)
				if (isObject(item))
					result.push(new JsonObject(item));
		}
		return result;
	}

	public function strings(name:String):Array<String> {
		var field:Dynamic = Reflect.field(value, name);
		var result:Array<String> = [];
		if (Std.isOfType(field, Array)) {
			var items:Array<Dynamic> = field;
			for (item in items)
				if (Std.isOfType(item, String))
					result.push(item);
		}
		return result;
	}
}
