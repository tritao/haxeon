package sys.io;

import haxe.io.Bytes;
import haxe.io.Eof;

#if wasm
/** A file of the session's in-memory file system, read through `File.read`; standard input has no host stream on Wasm. */
class FileInput extends haxe.io.Input {
	final content:Null<Bytes>;
	var position = 0;

	/** `content` is the whole file; without it this is standard input, which cannot be read. */
	internal function new(?content:Bytes)
		this.content = content;

	function bytes():Bytes {
		var bytes = content;
		if (bytes == null)
			throw "Standard input is not available on Wasm";
		return bytes;
	}

	override public function readByte():Int {
		var bytes = bytes();
		if (position >= bytes.length)
			throw new Eof();
		return bytes.get(position++);
	}

	override public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		var bytes = bytes();
		if (len == 0)
			return 0;
		if (position >= bytes.length)
			throw new Eof();
		var count = bytes.length - position < len ? bytes.length - position : len;
		s.blit(pos, bytes, position, count);
		position += count;
		return count;
	}

	/** Whether a read has reached the end of the file. */
	public function eof():Bool
		return position >= bytes().length;

	/** The read position, in bytes from the start of the file. */
	public function tell():Int
		return position;

	/** Moves the read position to `p` bytes from where `pos` says, within the file. */
	public function seek(p:Int, pos:FileSeek):Void {
		var target = switch pos {
			case SeekBegin: p;
			case SeekCur: position + p;
			case SeekEnd: bytes().length + p;
		};
		if (target < 0)
			throw "Cannot seek before the start of the file";
		position = target;
	}
}
#else
private typedef InputHandle = hl.Abstract<"realtime_file_input">;

@:hlNative("haxeon_runtime", "__file_input_read_byte")
internal extern function fileInputReadByte(input:InputHandle):Int;

@:hlNative("haxeon_runtime", "__file_input_read_bytes")
internal extern function fileInputReadBytes(input:InputHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__file_input_read_line")
internal extern function fileInputReadLine(input:InputHandle):Null<String>;

@:hlNative("haxeon_runtime", "__file_input_eof")
internal extern function fileInputEof(input:InputHandle):Bool;

@:hlNative("haxeon_runtime", "__file_input_tell")
internal extern function fileInputTell(input:InputHandle):Int;

@:hlNative("haxeon_runtime", "__file_input_seek")
internal extern function fileInputSeek(input:InputHandle, position:Int, kind:Int):Bool;

@:hlNative("haxeon_runtime", "__file_input_close")
internal extern function fileInputClose(input:InputHandle):Void;

/** A readable host stream: a file `File.read` opened, or standard input (`Sys.stdin()`). */
class FileInput extends haxe.io.Input {
	final handle:InputHandle;

	internal function new(handle:InputHandle)
		this.handle = handle;

	override public function readByte():Int {
		var code = fileInputReadByte(handle);
		if (code < 0)
			throw new Eof();
		return code;
	}

	override public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		if (len == 0)
			return 0;
		var count = fileInputReadBytes(handle, s, pos, len);
		if (count == 0)
			throw new Eof();
		return count;
	}

	/** A line without its "\n" or "\r\n", read by the host in one call; throws `haxe.io.Eof` when nothing is left. */
	override public function readLine():String {
		var line = fileInputReadLine(handle);
		if (line == null)
			throw new Eof();
		return line;
	}

	/** Closes a file; closing standard input leaves it open for the rest of the program. */
	override public function close():Void
		fileInputClose(handle);

	/** Whether a read has reached the end of the file. */
	public function eof():Bool
		return fileInputEof(handle);

	/** The read position, in bytes from the start of the file. */
	public function tell():Int
		return fileInputTell(handle);

	/** Moves the read position to `p` bytes from where `pos` says. Throws when it cannot. */
	public function seek(p:Int, pos:FileSeek):Void
		if (!fileInputSeek(handle, p, pos.getIndex()))
			throw "Could not seek in the file";
}
#end
