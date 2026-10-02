package sys.io;

#if wasm
/** Host-routed standard output stream. Flush publishes any unterminated line. */
class FileOutput {
	final error:Bool;

	public function new(error:Bool)
		this.error = error;

	public function writeString(value:String):Void
		haxeon.wasm.HaxeonHost.write_output(value, error ? 1 : 0);

	public function flush():Void
		haxeon.wasm.HaxeonHost.flush_output(error ? 1 : 0);
}
#else

/** Writable host stream used by Sys.stdout() and Sys.stderr(). */
extern abstract FileOutput(hl.Abstract<"realtime_file_output">) {
	@:hlNative("haxeon_runtime", "__file_output_write_string")
	public function writeString(value:String):Void;

	@:hlNative("haxeon_runtime", "__file_output_flush")
	public function flush():Void;
}
#end
