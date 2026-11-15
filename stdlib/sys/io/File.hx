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

#if !wasm
@:hlNative("haxeon_runtime", "__file_get_content")
extern function fileGetContent(path:String):String;

@:hlNative("haxeon_runtime", "__file_get_bytes")
extern function fileGetBytes(path:String):Bytes;

@:hlNative("haxeon_runtime", "__file_save_content")
extern function fileSaveContent(path:String, content:String):Void;

@:hlNative("haxeon_runtime", "__file_append_content")
extern function fileAppendContent(path:String, content:String):Void;

@:hlNative("haxeon_runtime", "__file_save_bytes")
extern function fileSaveBytes(path:String, bytes:Bytes):Void;

@:hlNative("haxeon_runtime", "__file_input_open")
extern function fileInputOpen(path:String, binary:Bool):hl.Abstract<"realtime_file_input">;

@:hlNative("haxeon_runtime", "__file_output_open")
extern function fileOutputOpen(path:String, append:Bool, binary:Bool):hl.Abstract<"realtime_file_output">;
#else
// Wasm keeps files in the session's in-memory filesystem (runtime.MemoryFileSystem).
function fileGetContent(path:String):String
	return runtime.MemoryFileSystem.getContent(path);

function fileGetBytes(path:String):Bytes
	return runtime.MemoryFileSystem.getBytes(path);

function fileSaveContent(path:String, content:String):Void
	runtime.MemoryFileSystem.saveContent(path, content);

function fileAppendContent(path:String, content:String):Void
	runtime.MemoryFileSystem.appendContent(path, content);

function fileSaveBytes(path:String, bytes:Bytes):Void
	runtime.MemoryFileSystem.saveBytes(path, bytes);
#end

/** Supported whole-file operations backed by the stable runtime ABI. */
class File {
	/** While `haxeon.build.InputFiles` is recording, every read is noted for the cache that depends on it. */
	public static function getContent(path:String):String {
		if (!haxeon.build.InputFiles.isRecording())
			return fileGetContent(path);
		var text:Null<String> = null;
		try
			text = fileGetContent(path)
		catch (error:Dynamic) {
			haxeon.build.InputFiles.readFailed(path);
			throw error;
		}
		haxeon.build.InputFiles.textRead(path, text);
		return text;
	}

	public static function getBytes(path:String):Bytes {
		if (!haxeon.build.InputFiles.isRecording())
			return fileGetBytes(path);
		var bytes:Null<Bytes> = null;
		try
			bytes = fileGetBytes(path)
		catch (error:Dynamic) {
			haxeon.build.InputFiles.readFailed(path);
			throw error;
		}
		haxeon.build.InputFiles.bytesRead(path, bytes);
		return bytes;
	}

	public static function saveContent(path:String, content:String):Void {
		haxeon.build.InputFiles.wrote(path);
		fileSaveContent(path, content);
	}

	public static function appendContent(path:String, content:String):Void {
		haxeon.build.InputFiles.wrote(path);
		fileAppendContent(path, content);
	}

	public static function saveBytes(path:String, bytes:Bytes):Void {
		haxeon.build.InputFiles.wrote(path);
		fileSaveBytes(path, bytes);
	}

	/**
	 * Opens `path` to read it as a stream; throws when it cannot be opened. While recording, what the file holds when it is
	 * opened is the input noted, as for `getBytes`. `binary` matters only on Windows, where text mode converts line ends.
	 */
	public static function read(path:String, binary:Bool = true):FileInput {
		if (haxeon.build.InputFiles.isRecording() && !haxeon.build.InputFiles.ignores(path))
			getBytes(path);
		#if wasm
		return new FileInput(fileGetBytes(path));
		#else
		return new FileInput(fileInputOpen(path, binary));
		#end
	}

	/** Creates or truncates `path` and opens it to write. */
	public static function write(path:String, binary:Bool = true):FileOutput {
		haxeon.build.InputFiles.wrote(path);
		#if wasm
		fileSaveBytes(path, Bytes.alloc(0));
		return new FileOutput(false, path);
		#else
		return new FileOutput(fileOutputOpen(path, false, binary));
		#end
	}

	/** Opens `path` to write at its end, creating it when missing. */
	public static function append(path:String, binary:Bool = true):FileOutput {
		haxeon.build.InputFiles.wrote(path);
		#if wasm
		if (!runtime.MemoryFileSystem.exists(path))
			fileSaveBytes(path, Bytes.alloc(0));
		return new FileOutput(false, path);
		#else
		return new FileOutput(fileOutputOpen(path, true, binary));
		#end
	}

	/** Copies the file at `srcPath` to `dstPath`, as Haxe's `File.copy`. */
	public static function copy(srcPath:String, dstPath:String):Void
		saveBytes(dstPath, getBytes(srcPath));
}
