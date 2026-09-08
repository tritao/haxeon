/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */
@:hlNative("realtime_runtime", "__reflect_compare")
extern function reflectCompare(left:Dynamic, right:Dynamic):Int;

@:hlNative("std", "fun_compare")
extern function reflectCompareMethods(left:Dynamic, right:Dynamic):Bool;

@:hlNative("realtime_runtime", "__reflect_field")
extern function reflectField(object:Dynamic, field:String):Dynamic;

@:hlNative("realtime_runtime", "__reflect_set_field")
extern function reflectSetField(object:Dynamic, field:String, value:Dynamic):Void;

@:hlNative("realtime_runtime", "__reflect_has_field")
extern function reflectHasField(object:Dynamic, field:String):Bool;

@:hlNative("realtime_runtime", "__reflect_field_count")
extern function reflectFieldCount(object:Dynamic):Int;

@:hlNative("realtime_runtime", "__reflect_field_name")
extern function reflectFieldName(object:Dynamic, index:Int):String;

@:hlNative("realtime_runtime", "__reflect_is_function")
extern function reflectIsFunction(value:Dynamic):Bool;

/** Supported reflection helpers backed by the stable runtime ABI. */
class Reflect {
	public static inline function field(object:Dynamic, field:String):Dynamic
		return reflectField(object, field);

	public static inline function setField(object:Dynamic, field:String, value:Dynamic):Void
		reflectSetField(object, field, value);

	public static inline function hasField(object:Dynamic, field:String):Bool
		return reflectHasField(object, field);

	public static function fields(object:Dynamic):Array<String> {
		var result:Array<String> = [];
		for (index in 0...reflectFieldCount(object)) result.push(reflectFieldName(object, index));
		return result;
	}

	public static inline function isFunction(value:Dynamic):Bool
		return reflectIsFunction(value);

	public static inline function compare(left:Dynamic, right:Dynamic):Int
		return reflectCompare(left, right);

	public static inline function compareMethods(left:Dynamic, right:Dynamic):Bool
		return reflectCompareMethods(left, right);
}
