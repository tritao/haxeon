package sys.io;

private typedef ProcessHandle = hl.Abstract<"hl_process">;

/** HashLink subprocess with argument-safe creation and blocking whole-stream capture. */
extern abstract Process(ProcessHandle) {
	@:hlNative("haxeon_runtime", "__process_run")
	public static function run(command:String, arguments:Array<String>):Process;

	@:hlNative("haxeon_runtime", "__process_read_stdout")
	public function readStdout():String;

	@:hlNative("haxeon_runtime", "__process_read_stderr")
	public function readStderr():String;

	@:hlNative("haxeon_runtime", "__process_exit")
	public function exitCode():Int;

	@:hlNative("haxeon_runtime", "__process_close")
	public function close():Void;

	@:hlNative("haxeon_runtime", "__process_kill")
	public function kill():Void;
}
