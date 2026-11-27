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
import std.fs.FileNatives;
import std.fs.FileNatives.WriteMode;

#if !wasm
@:hlNative("haxeon_runtime", "__file_input_open")
internal extern function fileInputOpen(path:String, binary:Bool):hl.Abstract<"realtime_file_input">;

@:hlNative("haxeon_runtime", "__file_output_open")
internal extern function fileOutputOpen(path:String, mode:Int, binary:Bool):hl.Abstract<"realtime_file_output">;
#end

/**
 * Files read and written whole, or opened as streams (`read`, `write`, `append`, `update`), as Haxe's API has them,
 * throwing where an operation fails. Whole files go through `std.fs`, which answers the same operations with a
 * `Result` instead; on Wasm the files are the session's in-memory filesystem.
 */
class File {
	/** The text of the file `path`, read as UTF-8. Throws when it cannot be read. */
	public static function getContent(path:String):String {
		var text = FileNatives.readText(null, path);
		if (text == null)
			throw failed("read", path);
		return text;
	}

	/** The bytes of the file `path`. Throws when it cannot be read. */
	public static function getBytes(path:String):Bytes {
		var bytes = FileNatives.read(null, path);
		if (bytes == null)
			throw failed("read", path);
		return bytes;
	}

	/** Writes `content`, in UTF-8, as the file `path`, replacing what it held. */
	public static function saveContent(path:String, content:String):Void
		saveBytes(path, Bytes.ofString(content == null ? "" : content));

	/** Adds `content`, in UTF-8, at the end of the file `path`, creating it when missing. */
	public static function appendContent(path:String, content:String):Void
		if (!FileNatives.write(null, path, Bytes.ofString(content == null ? "" : content), Append))
			throw failed("append to", path);

	/** Writes `bytes` as the file `path`, replacing what it held. */
	public static function saveBytes(path:String, bytes:Bytes):Void
		if (!FileNatives.write(null, path, bytes, Replace)) throw failed("write", path);

	/**
	 * Opens `path` to read it as a stream; throws when it cannot be opened. `binary` matters only on Windows, where text
	 * mode converts line ends.
	 */
	public static function read(path:String, binary:Bool = true):FileInput {
		#if wasm
		return new FileInput(getBytes(path));
		#else
		return new FileInput(fileInputOpen(path, binary));
		#end
	}

	/** Creates or truncates `path` and opens it to write. */
	public static function write(path:String, binary:Bool = true):FileOutput {
		#if wasm
		saveBytes(path, Bytes.alloc(0));
		return new FileOutput(path, Bytes.alloc(0), 0, false);
		#else
		return new FileOutput(fileOutputOpen(path, 0, binary));
		#end
	}

	/** Opens `path` to write at its end, creating it when missing. */
	public static function append(path:String, binary:Bool = true):FileOutput {
		#if wasm
		var existing = FileNatives.read(null, path);
		if (existing == null) {
			existing = Bytes.alloc(0);
			saveBytes(path, existing);
		}
		return new FileOutput(path, existing, existing.length, true);
		#else
		return new FileOutput(fileOutputOpen(path, 1, binary));
		#end
	}

	/** Opens the existing file at `path` to write over it from its start, keeping what is not overwritten, as Haxe's. */
	public static function update(path:String, binary:Bool = true):FileOutput {
		#if wasm
		return new FileOutput(path, getBytes(path), 0, false);
		#else
		return new FileOutput(fileOutputOpen(path, 2, binary));
		#end
	}

	/** Copies the file at `srcPath` to `dstPath`, as Haxe's `File.copy`. */
	public static function copy(srcPath:String, dstPath:String):Void
		saveBytes(dstPath, getBytes(srcPath));

	/** What a failed operation throws: `Could not read "a.txt": not found`. */
	static function failed(operation:String, path:String):String
		return 'Could not $operation "$path": ${FileNatives.lastError().describe()}';
}
