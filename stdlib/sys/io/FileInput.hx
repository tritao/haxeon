package sys.io;

#if wasm
/** Standard input: a Wasm module has no host stream to read. */
class FileInput extends haxe.io.Input {
	public function new() {}

	override public function readByte():Int
		throw "Standard input is not available on Wasm";
}
#else
private typedef InputHandle = hl.Abstract<"realtime_file_input">;

@:hlNative("haxeon_runtime", "__file_input_read_byte")
extern function fileInputReadByte(input:InputHandle):Int;

@:hlNative("haxeon_runtime", "__file_input_read_bytes")
extern function fileInputReadBytes(input:InputHandle, bytes:haxe.io.Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__file_input_read_line")
extern function fileInputReadLine(input:InputHandle):Null<String>;

/** A readable host stream, such as Sys.stdin(). */
class FileInput extends haxe.io.Input {
	final handle:InputHandle;

	public function new(handle:InputHandle)
		this.handle = handle;

	override public function readByte():Int {
		var code = fileInputReadByte(handle);
		if (code < 0)
			throw new haxe.io.Eof();
		return code;
	}

	override public function readBytes(s:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		if (len == 0)
			return 0;
		var count = fileInputReadBytes(handle, s, pos, len);
		if (count == 0)
			throw new haxe.io.Eof();
		return count;
	}

	/** A line without its "\n" or "\r\n", read by the host in one call; throws `haxe.io.Eof` when nothing is left. */
	override public function readLine():String {
		var line = fileInputReadLine(handle);
		if (line == null)
			throw new haxe.io.Eof();
		return line;
	}
}
#end
