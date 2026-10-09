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

#if wasm
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

	public function toString():String {
		// Wasm array joins concatenate the growing prefix. Copy UTF-8 chunks once instead.
		var chunks:Array<haxe.io.Bytes> = [];
		var size = 0;
		for (part in parts) {
			var bytes = haxe.io.Bytes.ofString(part);
			chunks.push(bytes);
			size += bytes.length;
		}
		var output = haxe.io.Bytes.alloc(size);
		var offset = 0;
		for (chunk in chunks) {
			output.blit(offset, chunk, 0, chunk.length);
			offset += chunk.length;
		}
		return output.toString();
	}
}
#else
private typedef StringBufferHandle = hl.Abstract<"realtime_string_buffer">;

@:hlNative("haxeon_runtime", "__string_buffer_new")
extern function stringBufferNew():StringBufferHandle;

@:hlNative("haxeon_runtime", "__string_buffer_add")
extern function stringBufferAdd(buffer:StringBufferHandle, value:String):Void;

@:hlNative("haxeon_runtime", "__string_buffer_length")
extern function stringBufferLength(buffer:StringBufferHandle):Int;

@:hlNative("haxeon_runtime", "__string_buffer_to_string")
extern function stringBufferToString(buffer:StringBufferHandle):String;

/**
 * An efficient mutable buffer for incrementally constructing strings. Characters are copied into one growing
 * UTF-16 buffer in the runtime, so what was appended does not stay alive until `toString`.
 */
class StringBuf {
	var buffer:StringBufferHandle;

	public var length(get, never):Int;

	public inline function new() {
		buffer = stringBufferNew();
	}

	inline function get_length():Int {
		return stringBufferLength(buffer);
	}

	public inline function add<T>(x:T):Void {
		stringBufferAdd(buffer, Std.string(x));
	}

	public inline function addChar(c:Int):Void {
		stringBufferAdd(buffer, String.fromCharCode(c));
	}

	public inline function addSub(s:String, pos:Int, ?len:Int):Void {
		stringBufferAdd(buffer, len == null ? s.substr(pos) : s.substr(pos, len));
	}

	public inline function toString():String {
		return stringBufferToString(buffer);
	}
}
#end
