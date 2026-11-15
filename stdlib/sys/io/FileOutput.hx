package sys.io;

import haxe.io.Bytes;

#if wasm
/**
 * A file of the session's in-memory file system, opened through `File.write` or `File.append`; standard output and error
 * (`Sys.stdout()`, `Sys.stderr()`) are a subclass routed to the host. Bytes are held until `flush` or `close`, so a
 * character written byte by byte arrives whole.
 */
class FileOutput extends haxe.io.Output {
	final path:String;
	var pending = new haxe.io.BytesBuffer();

	/** The file at `path`, which `File` has already created or truncated. */
	public function new(path:String)
		this.path = path;

	/** Standard output, or standard error when `error` is set. Only programs that use them link the host's output imports. */
	public static function host(error:Bool):FileOutput
		return new HostOutput(error);

	override public function writeByte(c:Int):Void
		pending.addByte(c);

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		pending.addBytes(s, pos, len);
		return len;
	}

	override public function flush():Void
		release(taken());

	override public function close():Void
		flush();

	/** The pending bytes, leaving none. */
	function taken():Bytes {
		var bytes = pending.getBytes();
		pending = new haxe.io.BytesBuffer();
		return bytes;
	}

	/** Appends `bytes` to the file. */
	function release(bytes:Bytes):Void {
		if (bytes.length == 0)
			return;
		var existing = runtime.MemoryFileSystem.exists(path) ? runtime.MemoryFileSystem.getBytes(path) : Bytes.alloc(0),
			combined = Bytes.alloc(existing.length + bytes.length);
		combined.blit(0, existing, 0, existing.length);
		combined.blit(existing.length, bytes, 0, bytes.length);
		runtime.MemoryFileSystem.saveBytes(path, combined);
	}
}

/** Standard output or error, written through the host. */
private class HostOutput extends FileOutput {
	final error:Bool;

	public function new(error:Bool) {
		super("");
		this.error = error;
	}

	/** Strings go to the host directly, after any bytes still held. */
	override public function writeString(s:String, ?encoding:haxe.io.Encoding):Void {
		release(taken());
		haxeon.wasm.HaxeonHost.write_output(s, error ? 1 : 0);
	}

	override public function flush():Void {
		release(taken());
		haxeon.wasm.HaxeonHost.flush_output(error ? 1 : 0);
	}

	override function release(bytes:Bytes):Void
		if (bytes.length > 0)
			haxeon.wasm.HaxeonHost.write_output(bytes.toString(), error ? 1 : 0);
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
