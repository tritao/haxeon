package sys.io;

import sys.io.ChildProcess;

private typedef ProcessHandle = hl.Abstract<"hl_process">;

/** Subprocess creation. Existing run/capture methods retain their blocking behavior. */
extern abstract Process(ProcessHandle) {
	/** Spawn an independent streaming process. Environment entries override inherited values. */
	@:hlNative("haxeon_runtime", "__process_spawn")
	public static function spawn(command:String, arguments:Array<String>, cwd:String = "",
		?environmentKeys:Array<String>, ?environmentValues:Array<String>, detached:Bool = false,
		newProcessGroup:Bool = true):ChildProcess;

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
