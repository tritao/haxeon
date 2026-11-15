package sys.io;

import haxe.io.Bytes;
import haxe.io.Eof;

#if wasm
/** Haxe's Process: a Wasm module cannot start processes. */
class Process {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output;

	public function new(cmd:String, ?args:Array<String>, ?detached:Bool)
		throw "Processes are not available on Wasm";

	public function getPid():Int
		throw "Processes are not available on Wasm";

	public function exitCode(block:Bool = true):Null<Int>
		throw "Processes are not available on Wasm";

	public function close():Void {}

	public function kill():Void {}
}
#else
private typedef ProcessHandle = hl.Abstract<"hl_process">;

@:hlNative("haxeon_runtime", "__process_open")
extern function processOpen(command:String, arguments:Null<Array<String>>, detached:Bool):ProcessHandle;

@:hlNative("haxeon_runtime", "__process_stdout_read")
extern function processStdoutRead(process:ProcessHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__process_stderr_read")
extern function processStderrRead(process:ProcessHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__process_stdin_write")
extern function processStdinWrite(process:ProcessHandle, bytes:Bytes, pos:Int, len:Int):Int;

@:hlNative("haxeon_runtime", "__process_stdin_close")
extern function processStdinClose(process:ProcessHandle):Bool;

@:hlNative("haxeon_runtime", "__process_exit")
extern function processExit(process:ProcessHandle, block:Bool):Int;

@:hlNative("haxeon_runtime", "__process_pid")
extern function processPid(process:ProcessHandle):Int;

@:hlNative("haxeon_runtime", "__process_close")
extern function processClose(process:ProcessHandle):Void;

@:hlNative("haxeon_runtime", "__process_kill")
extern function processKill(process:ProcessHandle):Void;

/** What the child writes to its standard output or error; the end of the input once it closes the stream. */
private class ProcessOutput extends haxe.io.Input {
	final process:ProcessHandle;
	final error:Bool;
	final single = Bytes.alloc(1);

	public function new(process:ProcessHandle, error:Bool) {
		this.process = process;
		this.error = error;
	}

	override public function readByte():Int {
		readBytes(single, 0, 1);
		return single.get(0);
	}

	override public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		if (len == 0)
			return 0;
		var count = error ? processStderrRead(process, s, pos, len) : processStdoutRead(process, s, pos, len);
		if (count < 0)
			throw new Eof();
		return count;
	}
}

/** What the program writes to the child's standard input. */
private class ProcessInput extends haxe.io.Output {
	final process:ProcessHandle;
	final single = Bytes.alloc(1);

	public function new(process:ProcessHandle)
		this.process = process;

	override public function writeByte(c:Int):Void {
		single.set(0, c);
		writeBytes(single, 0, 1);
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		var count = processStdinWrite(process, s, pos, len);
		if (count < 0)
			throw new Eof();
		return count;
	}

	/** Closes the child's standard input, so it sees the end of its input. */
	override public function close():Void
		if (!processStdinClose(process))
			throw "Could not close the process input";
}

/** A child process, as Haxe's sys.io.Process; `ChildProcess.spawn` adds an environment, a directory and nonblocking pipes. */
class Process {
	/** The minimum Int, which the runtime returns for an exit code while the child still runs. */
	static inline final RUNNING = -2147483648;

	final handle:ProcessHandle;

	/** The exit code, once read: waiting for a child reaps it, so it can be asked for only once. */
	var exited:Null<Int> = null;

	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output;

	/**
	 * Starts `cmd`. Without `args` the command line goes to the shell; with them `cmd` runs directly with exactly those
	 * arguments (on Windows they are quoted into the command line, as Haxe does).
	 */
	public function new(cmd:String, ?args:Array<String>, ?detached:Bool) {
		var command = cmd, arguments = args;
		if (arguments != null && Sys.systemName() == "Windows") {
			command = [for (part in [cmd].concat(arguments)) haxe.SysTools.quoteWinArg(part, true)].join(" ");
			arguments = null;
		}
		handle = processOpen(command, arguments, detached == true);
		stdout = new ProcessOutput(handle, false);
		stderr = new ProcessOutput(handle, true);
		stdin = new ProcessInput(handle);
	}

	public function getPid():Int
		return processPid(handle);

	/** The exit code; with `block` false, null while the child still runs. */
	public function exitCode(block:Bool = true):Null<Int> {
		var known = exited;
		if (known != null)
			return known;
		var code = processExit(handle, block);
		if (code == RUNNING)
			return null;
		exited = code;
		return code;
	}

	/** Releases the pipes and the process handle; the child keeps running. */
	public function close():Void
		processClose(handle);

	public function kill():Void
		processKill(handle);
}
#end
