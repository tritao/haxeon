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

package sys.io;

import haxe.io.Bytes;

@:hlNative("realtime_runtime", "__file_get_content")
extern function fileGetContent(path:String):String;

@:hlNative("realtime_runtime", "__file_save_content")
extern function fileSaveContent(path:String, content:String):Void;

@:hlNative("realtime_runtime", "__file_save_bytes")
extern function fileSaveBytes(path:String, bytes:Bytes):Void;

/** Supported whole-file operations backed by the stable runtime ABI. */
class File {
	public static inline function getContent(path:String):String
		return fileGetContent(path);

	public static inline function saveContent(path:String, content:String):Void
		fileSaveContent(path, content);

	public static inline function saveBytes(path:String, bytes:Bytes):Void
		fileSaveBytes(path, bytes);
}
