package sys.io;

#if wasm
/** Standard input: a Wasm module has no host stream to read. */
class FileInput {
	public function new() {}

	public function readLine():String
		throw "Standard input is not available on Wasm";
}
#else
@:hlNative("haxeon_runtime", "__file_input_read_line")
extern function fileInputReadLine(input:hl.Abstract<"realtime_file_input">):Null<String>;

/** Readable host stream used by Sys.stdin(). */
class FileInput {
	final handle:hl.Abstract<"realtime_file_input">;

	public function new(handle:hl.Abstract<"realtime_file_input">)
		this.handle = handle;

	/** The next line without its "\n" or "\r\n"; throws `haxe.io.Eof` at the end of the input. */
	public function readLine():String {
		var line = fileInputReadLine(handle);
		if (line == null)
			throw new haxe.io.Eof();
		return line;
	}
}
#end
