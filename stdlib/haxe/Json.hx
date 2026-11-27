/*
 * Copyright (C)2005-2019 Haxe Foundation
 * Distributed under the MIT license; see stdlib/LICENSE.
 */
package haxe;

/**
 * JSON text read into values and written from them. An object becomes an anonymous object, an array an
 * `Array<Dynamic>`, a number a `Float` or an `Int`. `haxeon.wire.JsonWire` reads and writes typed values instead.
 */
class Json {
	/** The value the JSON `text` holds. Throws when `text` is not JSON. */
	public static inline function parse(text:String):Dynamic
		return haxe.format.JsonParser.parse(text);

	/**
	 * `value` as JSON text: on one line, or indented by `space` per level when given. `replacer`, when given, is called
	 * with each key (an index in an array) and value, and what it returns is written instead.
	 */
	public static inline function stringify(value:Dynamic, ?replacer:(key:Dynamic, value:Dynamic) -> Dynamic,
			?space:String):String
		return haxe.format.JsonPrinter.print(value, replacer, space);
}
