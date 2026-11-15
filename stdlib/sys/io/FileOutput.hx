package sys.io;

import haxe.io.Bytes;

#if wasm
/**
 * Standard output or error, routed to the host, or a file of the session's in-memory file system opened through
 * `File.write` or `File.append`. Bytes are held until `flush`, `close` or (for a host stream) the next string, so a
 * character written byte by byte reaches the host whole.
 */
class FileOutput extends haxe.io.Output {
	final error:Bool;
	final path:Null<String>;
	var pending = new haxe.io.BytesBuffer();

	/** A host stream (`error` chooses standard error), or the file at `path`, which `File` has already created or truncated. */
	public function new(error:Bool, ?path:String) {
		this.error = error;
		this.path = path;
	}

	override public function writeByte(c:Int):Void
		pending.addByte(c);

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		pending.addBytes(s, pos, len);
		return len;
	}

	override public function writeString(s:String, ?encoding:haxe.io.Encoding):Void {
		if (path != null) {
			super.writeString(s, encoding);
			return;
		}
		release();
		haxeon.wasm.HaxeonHost.write_output(s, error ? 1 : 0);
	}

	override public function flush():Void {
		release();
		if (path == null)
			haxeon.wasm.HaxeonHost.flush_output(error ? 1 : 0);
	}

	override public function close():Void
		flush();

	/** Hands the pending bytes to the host stream or appends them to the file. */
	function release():Void {
		var bytes = pending.getBytes();
		pending = new haxe.io.BytesBuffer();
		if (bytes.length == 0)
			return;
		var file = path;
		if (file == null) {
			haxeon.wasm.HaxeonHost.write_output(bytes.toString(), error ? 1 : 0);
			return;
		}
		var existing = runtime.MemoryFileSystem.exists(file) ? runtime.MemoryFileSystem.getBytes(file) : Bytes.alloc(0),
			combined = Bytes.alloc(existing.length + bytes.length);
		combined.blit(0, existing, 0, existing.length);
		combined.blit(existing.length, bytes, 0, bytes.length);
		runtime.MemoryFileSystem.saveBytes(file, combined);
	}
}
#else
private typedef OutputHandle = hl.Abstract<"realtime_file_output">;

@:hlNative("haxeon_runtime", "__file_output_write_byte")
extern function fileOutputWriteByte(output:OutputHandle, value:Int):Void;

@:hlNative("haxeon_runtime", "__file_output_write_bytes")
extern function fileOutputWriteBytes(output:OutputHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__file_output_write_string")
extern function fileOutputWriteString(output:OutputHandle, value:String):Void;

@:hlNative("haxeon_runtime", "__file_output_flush")
extern function fileOutputFlush(output:OutputHandle):Void;

@:hlNative("haxeon_runtime", "__file_output_tell")
extern function fileOutputTell(output:OutputHandle):Int;

@:hlNative("haxeon_runtime", "__file_output_seek")
extern function fileOutputSeek(output:OutputHandle, position:Int, kind:Int):Bool;

@:hlNative("haxeon_runtime", "__file_output_close")
extern function fileOutputClose(output:OutputHandle):Void;

/** A writable host stream: a file `File.write` or `File.append` opened, or standard output or error. */
class FileOutput extends haxe.io.Output {
	final handle:OutputHandle;

	public function new(handle:OutputHandle)
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

	public function tell():Int
		return fileOutputTell(handle);

	public function seek(p:Int, pos:FileSeek):Void
		if (!fileOutputSeek(handle, p, pos.getIndex()))
			throw "Could not seek in the file";
}
#end
