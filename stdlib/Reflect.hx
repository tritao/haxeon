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
#if !wasm
@:hlNative("haxeon_runtime", "__reflect_compare")
extern function reflectCompare(left:Dynamic, right:Dynamic):Int;
#else

/**
 * HashLink's `hl_dyn_compare` order: null first, strings bytewise, numbers by value, and
 * `0xAABBCCDD` (HashLink's invalid-comparison result) for NaN or mismatched primitive kinds.
 * HashLink orders distinct objects by address, which Wasm does not expose; they compare as 1.
 */
function reflectCompare(left:Dynamic, right:Dynamic):Int {
	if (left == null)
		return right == null ? 0 : -1;
	if (right == null)
		return 1;
	if (Std.isOfType(left, String) || Std.isOfType(right, String)) {
		if (!Std.isOfType(left, String) || !Std.isOfType(right, String))
			return DynamicOrder.INVALID;
		// Typed as strings, Reflect.compare lowers to the bytewise string comparison intrinsic.
		var leftText:String = left, rightText:String = right;
		var order = Reflect.compare(leftText, rightText);
		return order < 0 ? -1 : order > 0 ? 1 : 0;
	}
	if (Std.isOfType(left, Int) && Std.isOfType(right, Int)) {
		var leftValue:Int = left, rightValue:Int = right;
		return leftValue == rightValue ? 0 : leftValue > rightValue ? 1 : -1;
	}
	var leftNumber = Std.isOfType(left, Int) || Std.isOfType(left, Float),
		rightNumber = Std.isOfType(right, Int) || Std.isOfType(right, Float);
	if (leftNumber || rightNumber) {
		if (!leftNumber || !rightNumber)
			return DynamicOrder.INVALID;
		var leftValue = numberValue(left), rightValue = numberValue(right);
		return leftValue == rightValue ? 0 : leftValue > rightValue ? 1 : leftValue < rightValue ? -1 : DynamicOrder.INVALID;
	}
	if (Std.isOfType(left, Bool) || Std.isOfType(right, Bool)) {
		if (!Std.isOfType(left, Bool) || !Std.isOfType(right, Bool))
			return DynamicOrder.INVALID;
		var leftValue:Bool = left, rightValue:Bool = right;
		return leftValue == rightValue ? 0 : leftValue ? 1 : -1;
	}
	return left == right ? 0 : 1;
}

/** A boxed Int or Float as a Float; Wasm boxes keep the two kinds apart. */
function numberValue(value:Dynamic):Float {
	if (Std.isOfType(value, Int)) {
		var integer:Int = value;
		return integer;
	}
	return value;
}

private class DynamicOrder {
	public static inline var INVALID = 0xAABBCCDD;
}
#end

@:hlNative("std", "fun_compare")
extern function reflectCompareMethods(left:Dynamic, right:Dynamic):Bool;

#if !wasm
@:hlNative("haxeon_runtime", "__reflect_field")
extern function reflectField(object:Dynamic, field:String):Dynamic;

@:hlNative("haxeon_runtime", "__reflect_set_field")
extern function reflectSetField(object:Dynamic, field:String, value:Dynamic):Void;

@:hlNative("haxeon_runtime", "__reflect_has_field")
extern function reflectHasField(object:Dynamic, field:String):Bool;

@:hlNative("haxeon_runtime", "__reflect_delete_field")
extern function reflectDeleteField(object:Dynamic, field:String):Bool;

@:hlNative("haxeon_runtime", "__reflect_field_count")
extern function reflectFieldCount(object:Dynamic):Int;

@:hlNative("haxeon_runtime", "__reflect_field_name")
extern function reflectFieldName(object:Dynamic, index:Int):String;
#else
@:hlNative("haxeon_runtime", "__reflect_object_copy")
extern function reflectObjectCopy(object:Dynamic):Dynamic;

// Wasm has no runtime field lookup: dynamic objects are runtime.DynamicObject, and the compiler
// generates the __reflect_object_* functions from compiled class and anonymous record layouts.

@:hlNative("haxeon_runtime", "__reflect_object_field")
extern function reflectObjectField(object:Dynamic, field:String):Dynamic;

@:hlNative("haxeon_runtime", "__reflect_object_set_field")
extern function reflectObjectSetField(object:Dynamic, field:String, value:Dynamic):Bool;

@:hlNative("haxeon_runtime", "__reflect_object_delete_field")
extern function reflectObjectDeleteField(object:Dynamic, field:String):Bool;

@:hlNative("haxeon_runtime", "__reflect_object_field_count")
extern function reflectObjectFieldCount(object:Dynamic):Int;

@:hlNative("haxeon_runtime", "__reflect_object_field_name")
extern function reflectObjectFieldName(object:Dynamic, index:Int):String;

function reflectField(object:Dynamic, field:String):Dynamic {
	var dynamicObject = runtime.DynamicObject.of(object);
	return dynamicObject == null ? reflectObjectField(object, field) : dynamicObject.get(field);
}

function reflectSetField(object:Dynamic, field:String, value:Dynamic):Void {
	var dynamicObject = runtime.DynamicObject.of(object);
	if (dynamicObject != null)
		dynamicObject.set(field, value);
	else if (!reflectObjectSetField(object, field, value))
		throw 'Reflect.setField cannot add field "$field" to a typed object on Wasm';
}

function reflectHasField(object:Dynamic, field:String):Bool {
	var dynamicObject = runtime.DynamicObject.of(object);
	if (dynamicObject != null)
		return dynamicObject.has(field);
	for (index in 0...reflectObjectFieldCount(object))
		if (reflectObjectFieldName(object, index) == field)
			return true;
	return false;
}

/** Compiled class and anonymous record layouts are fixed on Wasm: only dynamic objects lose fields, and a typed object's field is reset. */
function reflectDeleteField(object:Dynamic, field:String):Bool {
	var dynamicObject = runtime.DynamicObject.of(object);
	return dynamicObject == null ? reflectObjectDeleteField(object, field) : dynamicObject.remove(field);
}

function reflectFieldCount(object:Dynamic):Int {
	var dynamicObject = runtime.DynamicObject.of(object);
	return dynamicObject == null ? reflectObjectFieldCount(object) : dynamicObject.count();
}

function reflectFieldName(object:Dynamic, index:Int):String {
	var dynamicObject = runtime.DynamicObject.of(object);
	return dynamicObject == null ? reflectObjectFieldName(object, index) : dynamicObject.nameAt(index);
}
#end

@:hlNative("haxeon_runtime", "__reflect_is_function")
extern function reflectIsFunction(value:Dynamic):Bool;

@:hlNative("haxeon_runtime", "__reflect_is_object")
extern function reflectIsObject(value:Dynamic):Bool;

#if !wasm
@:hlNative("haxeon_runtime", "__reflect_copy")
extern function reflectCopy(object:Dynamic):Dynamic;
#end

/** Supported reflection helpers backed by the stable runtime ABI. */
class Reflect {
	public static function copy(object:Dynamic):Dynamic {
		#if wasm
		if (object == null)
			return null;
		var dynamicObject = runtime.DynamicObject.of(object);
		if (dynamicObject == null)
			return reflectObjectCopy(object);
		var result:Dynamic = {};
		for (name in fields(object))
			setField(result, name, field(object, name));
		return result;
		#else
		// The native adapter retains declaration types, including null-valued fields.
		return reflectCopy(object);
		#end
	}

	public static inline function field(object:Dynamic, field:String):Dynamic
		return reflectField(object, field);

	public static inline function setField(object:Dynamic, field:String, value:Dynamic):Void
		reflectSetField(object, field, value);

	public static inline function hasField(object:Dynamic, field:String):Bool
		return reflectHasField(object, field);

	/** Removes a field from a dynamic object; returns false when it was absent. */
	public static inline function deleteField(object:Dynamic, field:String):Bool
		return reflectDeleteField(object, field);

	public static function fields(object:Dynamic):Array<String> {
		var result:Array<String> = [];
		for (index in 0...reflectFieldCount(object))
			result.push(reflectFieldName(object, index));
		return result;
	}

	public static inline function isFunction(value:Dynamic):Bool
		return reflectIsFunction(value);

	public static inline function isObject(value:Dynamic):Bool
		return reflectIsObject(value);

	public static inline function compare(left:Dynamic, right:Dynamic):Int
		return reflectCompare(left, right);

	public static inline function compareMethods(left:Dynamic, right:Dynamic):Bool
		return reflectCompareMethods(left, right);
}
