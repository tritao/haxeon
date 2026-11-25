package haxeon.ui.core;

/** Typed accessors for arguments supplied by palettes, menus, or scripts. */
class CommandParameters {
	final values:Map<String, Dynamic>;

	/** No parameters. */
	public function new() {
		values = new Map();
	}

	/** Whether a value named `name` is set. */
	public function has(name:String):Bool
		return name != null && values.exists(name);

	/** Sets the value named `name`. Throws when `name` is empty. */
	public function set(name:String, value:Dynamic):Void {
		if (name == null || name.length == 0)
			throw "Command parameter names require a stable name";
		values.set(name, value);
	}

	/** Sets the text named `name`. */
	public function setString(name:String, value:String):Void
		set(name, value);

	/** Sets the flag named `name`. */
	public function setBool(name:String, value:Bool):Void
		set(name, value);

	/** Sets the number named `name`. */
	public function setFloat(name:String, value:Float):Void
		set(name, value);

	/** Sets the integer named `name`. */
	public function setInt(name:String, value:Int):Void
		set(name, value);

	/** The text named `name`, or null when it is missing or not text. */
	public function getString(name:String):Null<String> {
		var value = values.get(name);
		return value == null || !Std.isOfType(value, String) ? null : cast value;
	}

	/** The flag named `name`, or null when it is missing or not a flag. */
	public function getBool(name:String):Null<Bool> {
		var value = values.get(name);
		return value == null || !Std.isOfType(value, Bool) ? null : cast value;
	}

	/** The number named `name`, an integer included, or null when it is missing or not a number. */
	public function getFloat(name:String):Null<Float> {
		var value = values.get(name);
		if (value == null || (!Std.isOfType(value, Float) && !Std.isOfType(value, Int)))
			return null;
		return cast value;
	}

	/** The number named `name`, truncated to an integer, or null when it is missing or not a number. */
	public function getInt(name:String):Null<Int> {
		var value = values.get(name);
		if (value == null || (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)))
			return null;
		return Std.int(value);
	}

	/** The value named `name`, whatever its type, or null. */
	public function get(name:String):Dynamic
		return values.get(name);

	/** An independent copy of the parameters. */
	public function copy():CommandParameters {
		var result = new CommandParameters();
		for (name in values.keys())
			result.set(name, values.get(name));
		return result;
	}
}
