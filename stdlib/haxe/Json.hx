/*
 * Copyright (C)2005-2019 Haxe Foundation
 * Distributed under the MIT license; see stdlib/LICENSE.
 */
package haxe;

class Json {
	public static inline function parse(text:String):Dynamic
		return haxe.format.JsonParser.parse(text);

	public static inline function stringify(value:Dynamic, ?replacer:(key:Dynamic, value:Dynamic)->Dynamic, ?space:String):String
		return haxe.format.JsonPrinter.print(value, replacer, space);
}
