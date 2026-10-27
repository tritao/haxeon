package haxeon.agent;

/** Builds JSON text without untyped values. Callers keep commas and nesting balanced through the helpers. */
class JsonWriter {
	public static function quote(text:String):String
		return haxe.Json.stringify(text);

	public static function field(name:String, rawValue:String):String
		return quote(name) + ":" + rawValue;

	public static function stringField(name:String, value:String):String
		return field(name, quote(value));

	public static function object(fields:Array<String>):String
		return "{" + fields.join(",") + "}";

	public static function array(items:Array<String>):String
		return "[" + items.join(",") + "]";
}
