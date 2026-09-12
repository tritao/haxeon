package sys.io;

/** Writable host stream used by Sys.stdout() and Sys.stderr(). */
extern abstract FileOutput(hl.Abstract<"realtime_file_output">) {
	@:hlNative("haxeon_runtime", "__file_output_write_string")
	public function writeString(value:String):Void;

	@:hlNative("haxeon_runtime", "__file_output_flush")
	public function flush():Void;
}
