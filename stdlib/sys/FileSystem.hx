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

package sys;

@:hlNative("realtime_runtime", "__sys_exists")
extern function fileSystemExists(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_is_dir")
extern function fileSystemIsDirectory(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_full_path")
extern function fileSystemFullPath(path:String):String;

@:hlNative("realtime_runtime", "__sys_read_dir")
extern function fileSystemReadDirectory(path:String):Array<String>;

@:hlNative("realtime_runtime", "__sys_create_dir")
extern function fileSystemCreateDirectory(path:String, mode:Int):Bool;

@:hlNative("realtime_runtime", "__sys_delete")
extern function fileSystemDeleteFile(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_remove_dir")
extern function fileSystemDeleteDirectory(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_rename")
extern function fileSystemRename(path:String, newPath:String):Bool;

/** Supported filesystem queries backed by the stable runtime ABI. */
class FileSystem {
	public static inline function exists(path:String):Bool
		return fileSystemExists(path);

	public static inline function isDirectory(path:String):Bool
		return fileSystemIsDirectory(path);

	public static inline function fullPath(path:String):String
		return fileSystemFullPath(path);

	public static inline function absolutePath(path:String):String
		return fileSystemFullPath(path);

	public static inline function readDirectory(path:String):Array<String>
		return fileSystemReadDirectory(path);

	public static inline function createDirectory(path:String):Void
		fileSystemCreateDirectory(path, 493);

	public static inline function deleteFile(path:String):Void
		fileSystemDeleteFile(path);

	public static inline function deleteDirectory(path:String):Void
		fileSystemDeleteDirectory(path);

	public static inline function rename(path:String, newPath:String):Void
		fileSystemRename(path, newPath);
}
