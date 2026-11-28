package std.fs;

import haxe.Int64;
import std.bytes.Bytes;
import std.fs.FileError;
import std.fs.FileNatives;
import std.fs.FileNatives.RootHandle;
import std.fs.FileNatives.WriteMode;
import std.io.Reader;
import std.io.Writer;
#if wasm
import runtime.MemoryFileSystem as Memory;
#end

#if !wasm
/** The runtime's open file (native/runtime/fs.c). */
internal typedef StreamHandle = hl.Abstract<"realtime_fs_handle">;

// Bound here rather than in FileNatives, which every program reading files through sys.FileSystem loads.
@:hlNative("haxeon_runtime", "__fs_stream_open")
internal extern function streamOpen(root:Null<RootHandle>, path:String, mode:Int):Null<StreamHandle>;

@:hlNative("haxeon_runtime", "__fs_stream_read")
internal extern function streamRead(stream:StreamHandle, buffer:Bytes, offset:Int, length:Int):Int;

@:hlNative("haxeon_runtime", "__fs_stream_write")
internal extern function streamWrite(stream:StreamHandle, buffer:Bytes, offset:Int, length:Int):Bool;

@:hlNative("haxeon_runtime", "__fs_stream_seek")
internal extern function streamSeek(stream:StreamHandle, place:Bytes, origin:Int):Bool;

@:hlNative("haxeon_runtime", "__fs_stream_size")
internal extern function streamSize(stream:StreamHandle, out:Bytes):Bool;

@:hlNative("haxeon_runtime", "__fs_stream_set_length")
internal extern function streamSetLength(stream:StreamHandle, length:Bytes):Bool;

@:hlNative("haxeon_runtime", "__fs_stream_sync")
internal extern function streamSync(stream:StreamHandle):Bool;

@:hlNative("haxeon_runtime", "__fs_stream_close")
internal extern function streamClose(stream:StreamHandle):Bool;
#end

/**
 * An open file, read and written a part at a time from a position that moves with each read and write (`seek` moves
 * it too). Opened by path as `Files` resolves it (`FileHandle.open`), or beneath a `Root` (`root.openFile`). Each
 * operation answers a `Result` whose `Err` says why it failed. Using a closed handle throws; `close` it when done, or
 * bind it `scoped`. On Wasm it is a file of the session's in-memory filesystem.
 */
class FileHandle implements Disposable {
	#if wasm
	var full:Null<String>;
	final mode:OpenMode;
	var at:Int = 0;

	function new(full:String, mode:OpenMode) {
		this.full = full;
		this.mode = mode;
	}
	#else
	var handle:Null<StreamHandle>;
	final scratch = Bytes.alloc(8);

	function new(handle:StreamHandle)
		this.handle = handle;
	#end

	/** Opens the file `path` as `mode` says. */
	public static function open(path:Path, mode:OpenMode):Result<FileHandle, FileError>
		return openIn(null, path, mode);

	internal static function openIn(root:Null<RootHandle>, path:Path, mode:OpenMode):Result<FileHandle, FileError> {
		#if wasm
		var full = FileNatives.resolve(root, path.toString());
		if (full == null)
			return Err(FileNatives.lastError());
		var ready = switch mode {
			case Read | ReadWrite: FileNatives.read(root, path.toString()) != null;
			case Write: FileNatives.write(root, path.toString(), Bytes.alloc(0), Replace);
			case Append: FileNatives.write(root, path.toString(), Bytes.alloc(0), Append);
			case CreateNew: FileNatives.write(root, path.toString(), Bytes.alloc(0), Create);
		};
		return ready ? Ok(new FileHandle(full, mode)) : Err(FileNatives.lastError());
		#else
		var opened = streamOpen(root, path.toString(), mode.getIndex());
		return opened == null ? Err(FileNatives.lastError()) : Ok(new FileHandle(opened));
		#end
	}

	/**
	 * Reads up to `length` bytes into `buffer` from `offset` (by default all of it): how many it read, which is 0 at
	 * the file's end and may be fewer than asked before it.
	 */
	public function read(buffer:Bytes, offset:Int = 0, length:Int = -1):Result<Int, FileError> {
		var count = length < 0 ? buffer.length - offset : length;
		checkRange(buffer, offset, count);
		#if wasm
		var content = Memory.getBytes(live());
		var available = Std.int(Math.max(0, Math.min(count, content.length - at)));
		buffer.blit(offset, content, at, available);
		at += available;
		return Ok(available);
		#else
		var read = streamRead(live(), buffer, offset, count);
		return read < 0 ? Err(FileNatives.lastError()) : Ok(read);
		#end
	}

	/** Writes `length` bytes of `buffer` from `offset` (by default all of it), every one of them. */
	public function write(buffer:Bytes, offset:Int = 0, length:Int = -1):Result<Void, FileError> {
		var count = length < 0 ? buffer.length - offset : length;
		checkRange(buffer, offset, count);
		#if wasm
		var full = live();
		if (mode == Read)
			return Err(PermissionDenied);
		var content = Memory.getBytes(full);
		var start = mode == Append ? content.length : at;
		var grown = Bytes.alloc(Std.int(Math.max(content.length, start + count)));
		grown.blit(0, content, 0, content.length);
		grown.blit(start, buffer, offset, count);
		Memory.saveBytes(full, grown);
		at = start + count;
		return Ok();
		#else
		return streamWrite(live(), buffer, offset, count) ? Ok() : Err(FileNatives.lastError());
		#end
	}

	/** Writes `text` as UTF-8. */
	public function writeText(text:String):Result<Void, FileError>
		return write(Bytes.ofString(text));

	/** The file as a `Reader`, which reads from the position as `read` does and moves it. */
	public function reader():Reader<FileError>
		return new FileHandleReader(this);

	/** The file as a `Writer`, which writes at the position as `write` does and moves it. */
	public function writer():Writer<FileError>
		return new FileHandleWriter(this);

	/** Moves the position `offset` bytes from `from`, answering where it is now. */
	public function seek(offset:Int64, from:SeekFrom = Start):Result<Int64, FileError> {
		#if wasm
		var base = switch from {
			case Start: 0;
			case Current: at;
			case End: Memory.getBytes(live()).length;
		};
		var target = Int64.add(Int64.ofInt(base), offset);
		if (target < 0 || target > Int64.ofInt(0x7fffffff))
			return Err(Io(22, "the position is outside what a file can hold here"));
		at = target.low;
		return Ok(target);
		#else
		scratch.setInt64(0, offset);
		return streamSeek(live(), scratch, from.getIndex()) ? Ok(scratch.getInt64(0)) : Err(FileNatives.lastError());
		#end
	}

	/** Where the next read or write starts. */
	public function position():Result<Int64, FileError>
		return seek(0, Current);

	/** How long the file is, in bytes. */
	public function size():Result<Int64, FileError> {
		#if wasm
		return Ok(Int64.ofInt(Memory.getBytes(live()).length));
		#else
		return streamSize(live(), scratch) ? Ok(scratch.getInt64(0)) : Err(FileNatives.lastError());
		#end
	}

	/** Makes the file `length` bytes long, cutting it or adding zero bytes at its end; the position stays. */
	public function setLength(length:Int64):Result<Void, FileError> {
		#if wasm
		var full = live();
		if (mode == Read)
			return Err(PermissionDenied);
		if (length < 0 || length > Int64.ofInt(0x7fffffff))
			return Err(Io(22, "the length is outside what a file can hold here"));
		var content = Memory.getBytes(full), resized = Bytes.alloc(length.low);
		resized.blit(0, content, 0, Std.int(Math.min(content.length, length.low)));
		Memory.saveBytes(full, resized);
		return Ok();
		#else
		scratch.setInt64(0, length);
		return streamSetLength(live(), scratch) ? Ok() : Err(FileNatives.lastError());
		#end
	}

	/** Waits until what was written is on the disk, as `Files.writeAtomic` does before it moves a file into place. */
	public function sync():Result<Void, FileError> {
		#if wasm
		live();
		return Ok();
		#else
		return streamSync(live()) ? Ok() : Err(FileNatives.lastError());
		#end
	}

	/** Whether `close` has been called. */
	public function isClosed():Bool {
		#if wasm
		return full == null;
		#else
		return handle == null;
		#end
	}

	/**
	 * Closes the file; the handle cannot be used afterwards, and closing it again does nothing. Answers a failure the
	 * system reported as it closed (a write it could not finish).
	 */
	public function close():Result<Void, FileError> {
		#if wasm
		full = null;
		return Ok();
		#else
		var held = handle;
		handle = null;
		return held == null || streamClose(held) ? Ok() : Err(FileNatives.lastError());
		#end
	}

	/** Closes the file, as `close` does, without its answer. */
	public function dispose():Void
		_ = close();

	static function checkRange(buffer:Bytes, offset:Int, length:Int):Void
		if (buffer == null || offset < 0 || length < 0 || offset > buffer.length - length)
			throw new haxe.Exception("std.fs.FileHandle: the range is outside the buffer");

	#if wasm
	function live():String {
		var held = full;
		if (held == null)
			throw new haxe.Exception("std.fs.FileHandle is closed");
		return held;
	}
	#else
	function live():StreamHandle {
		var held = handle;
		if (held == null)
			throw new haxe.Exception("std.fs.FileHandle is closed");
		return held;
	}
	#end
}

/** A file's reads as a `Reader` (`FileHandle.reader`). */
private class FileHandleReader extends Reader<FileError> {
	final handle:FileHandle;

	public function new(handle:FileHandle)
		this.handle = handle;

	function readRange(buffer:Bytes, offset:Int, length:Int):Result<Int, FileError>
		return handle.read(buffer, offset, length);
}

/** A file's writes as a `Writer` (`FileHandle.writer`). */
private class FileHandleWriter extends Writer<FileError> {
	final handle:FileHandle;

	public function new(handle:FileHandle)
		this.handle = handle;

	function writeRange(buffer:Bytes, offset:Int, length:Int):Result<Void, FileError>
		return handle.write(buffer, offset, length);
}
