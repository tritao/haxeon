package sys.io;

import haxe.io.Bytes;

#if wasm
/**
 * A file of the session's in-memory file system, opened through `File.write`, `File.append` or `File.update`, as a
 * position in its bytes; `flush` and `close` store them. Standard output and error (`Sys.stdout()`, `Sys.stderr()`) are a
 * subclass routed to the host.
 */
class FileOutput extends haxe.io.Output {
	final path:String;

	/** Every write goes to the end, as a file opened to append does whatever `seek` says. */
	final appending:Bool;

	var content:Bytes;
	var length:Int;
	var position:Int;

	/** The file at `path` holding `content`, written from `position`. */
	internal function new(path:String, content:Bytes, position:Int, appending:Bool) {
		this.path = path;
		this.content = content;
		this.length = content.length;
		this.position = position;
		this.appending = appending;
	}

	/** Standard output, or standard error when `error` is set. Only programs that use them link the host's output imports. */
	public static function host(error:Bool):FileOutput
		return new HostOutput(error);

	override public function writeByte(c:Int):Void {
		reserve(1);
		content.set(position++, c);
		if (position > length)
			length = position;
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		reserve(len);
		content.blit(position, s, pos, len);
		position += len;
		if (position > length)
			length = position;
		return len;
	}

	override public function flush():Void
		runtime.MemoryFileSystem.saveBytes(path, content.sub(0, length));

	override public function close():Void
		flush();

	/** The write position, in bytes from the start of the file. */
	public function tell():Int
		return position;

	/** Moves the write position; past the end, the gap reads as zero bytes once something is written there. */
	public function seek(p:Int, pos:FileSeek):Void {
		var target = switch pos {
			case SeekBegin: p;
			case SeekCur: position + p;
			case SeekEnd: length + p;
		};
		if (target < 0)
			throw "Cannot seek before the start of the file";
		position = target;
	}

	/** Room for `count` more bytes at the write position, which an appending file moves to the end first. */
	function reserve(count:Int):Void {
		if (appending)
			position = length;
		if (position + count <= content.length)
			return;
		var capacity = content.length < 64 ? 64 : content.length * 2;
		while (capacity < position + count)
			capacity *= 2;
		var grown = Bytes.alloc(capacity);
		grown.blit(0, content, 0, length);
		content = grown;
	}
}

/** Standard output or error, written through the host; bytes are held until a string or `flush`, so a character arrives whole. */
private class HostOutput extends FileOutput {
	final error:Bool;
	var pending = new haxe.io.BytesBuffer();

	internal function new(error:Bool) {
		super("", Bytes.alloc(0), 0, true);
		this.error = error;
	}

	override public function writeByte(c:Int):Void
		pending.addByte(c);

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		pending.addBytes(s, pos, len);
		return len;
	}

	override public function writeString(s:String, ?encoding:haxe.io.Encoding):Void {
		release();
		haxeon.wasm.HaxeonHost.write_output(s, error ? 1 : 0);
	}

	override public function flush():Void {
		release();
		haxeon.wasm.HaxeonHost.flush_output(error ? 1 : 0);
	}

	override public function tell():Int
		throw "Standard streams have no position";

	override public function seek(p:Int, pos:FileSeek):Void
		throw "Standard streams have no position";

	function release():Void {
		var bytes = pending.getBytes();
		pending = new haxe.io.BytesBuffer();
		if (bytes.length > 0)
			haxeon.wasm.HaxeonHost.write_output(bytes.toString(), error ? 1 : 0);
	}
}
#else
private typedef OutputHandle = hl.Abstract<"realtime_file_output">;

@:hlNative("haxeon_runtime", "__file_output_write_byte")
internal extern function fileOutputWriteByte(output:OutputHandle, value:Int):Void;

@:hlNative("haxeon_runtime", "__file_output_write_bytes")
internal extern function fileOutputWriteBytes(output:OutputHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__file_output_write_string")
internal extern function fileOutputWriteString(output:OutputHandle, value:String):Void;

@:hlNative("haxeon_runtime", "__file_output_flush")
internal extern function fileOutputFlush(output:OutputHandle):Void;

@:hlNative("haxeon_runtime", "__file_output_tell")
internal extern function fileOutputTell(output:OutputHandle):Int;

@:hlNative("haxeon_runtime", "__file_output_seek")
internal extern function fileOutputSeek(output:OutputHandle, position:Int, kind:Int):Bool;

@:hlNative("haxeon_runtime", "__file_output_close")
internal extern function fileOutputClose(output:OutputHandle):Void;

/** A writable host stream: a file `File.write` or `File.append` opened, or standard output or error. */
class FileOutput extends haxe.io.Output {
	final handle:OutputHandle;

	internal function new(handle:OutputHandle)
		this.handle = handle;

	override public function writeByte(c:Int):Void
		fileOutputWriteByte(handle, c);

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		var count = fileOutputWriteBytes(handle, s, pos, len);
		if (count < len && len > 0 && count == 0)
			throw "Could not write file output";
		return count;
	}

	/** Writes the string's UTF-8 in one host call. */
	override public function writeString(s:String, ?encoding:haxe.io.Encoding):Void
		fileOutputWriteString(handle, s);

	override public function flush():Void
		fileOutputFlush(handle);

	/** Closes a file; closing standard output or error only flushes it. */
	override public function close():Void
		fileOutputClose(handle);

	/** The write position, in bytes from the start of the file. */
	public function tell():Int
		return fileOutputTell(handle);

	/** Moves the write position to `p` bytes from where `pos` says. Throws when it cannot. */
	public function seek(p:Int, pos:FileSeek):Void
		if (!fileOutputSeek(handle, p, pos.getIndex()))
			throw "Could not seek in the file";
}
#end
