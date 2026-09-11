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

/** An efficient mutable buffer for incrementally constructing strings. */
class StringBuf {
	var parts:Array<String>;
	var totalLength:Int;

	public var length(get, never):Int;

	public inline function new() {
		parts = [];
		totalLength = 0;
	}

	inline function get_length():Int {
		return totalLength;
	}

	public inline function add<T>(x:T):Void {
		var value = Std.string(x);
		parts.push(value);
		totalLength += value.length;
	}

	public inline function addChar(c:Int):Void {
		parts.push(String.fromCharCode(c));
		totalLength++;
	}

	public inline function addSub(s:String, pos:Int, ?len:Int):Void {
		var value = len == null ? s.substr(pos) : s.substr(pos, len);
		parts.push(value);
		totalLength += value.length;
	}

	public inline function toString():String {
		return parts.join("");
	}
}
