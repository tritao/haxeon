package runtime;

#if wasm
/**
 * Dynamic objects for Wasm, which has no native dynamic-object runtime. HashLink uses its own
 * `HDYNOBJ` instead. Fields keep insertion order.
 */
class DynamicObject {
	final indices:Map<String, Int> = [];
	final names:Array<String> = [];
	final values:Array<Dynamic> = [];

	public function new() {}

	/** Allocation for `{...}` literals typed as Dynamic. */
	public static function create():DynamicObject
		return new DynamicObject();

	/** Field initialization for `{...}` literals typed as Dynamic. */
	public static function initialize(object:DynamicObject, name:String, value:Dynamic):Void
		object.set(name, value);

	/** The dynamic object behind `value`, or null when it is any other value. */
	public static function of(value:Dynamic):Null<DynamicObject>
		return Std.isOfType(value, DynamicObject) ? cast value : null;

	public function get(name:String):Dynamic {
		var index = indices.get(name);
		return index == null ? null : values[index];
	}

	public function set(name:String, value:Dynamic):Void {
		var index = indices.get(name);
		if (index == null) {
			indices.set(name, names.length);
			names.push(name);
			values.push(value);
		} else
			values[index] = value;
	}

	public function has(name:String):Bool
		return indices.exists(name);

	public function count():Int
		return names.length;

	public function nameAt(index:Int):Null<String>
		return index < 0 || index >= names.length ? null : names[index];

	public function toString():String {
		var output = new StringBuf();
		output.add("{");
		for (index in 0...names.length) {
			if (index > 0)
				output.add(", ");
			output.add(names[index]);
			output.add(" : ");
			output.add(Std.string(values[index]));
		}
		output.add("}");
		return output.toString();
	}
}
#end
