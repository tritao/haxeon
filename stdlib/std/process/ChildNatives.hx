package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes or read its own environment"
#end
import haxe.io.Bytes;

/** The runtime's child process (native/runtime/child_processes.c). */
internal typedef ChildHandle = hl.Abstract<"realtime_child_process">;

/** What a wait waits for, and what it answers ready. */
internal enum abstract Readiness(Int) to Int {
	final Stdout = 1;
	final Stderr = 2;
	final Stdin = 4;
	final Exit = 8;
}

/** How a child starts. */
internal enum abstract SpawnFlag(Int) to Int {
	final Detached = 1;
	final Group = 2;
	final Verbatim = 4;
	final ReplaceEnvironment = 8;
}

@:hlNative("haxeon_runtime", "__child_spawn")
internal extern function spawn(command:String, arguments:Array<String>, directory:String, keys:Array<String>,
		values:Array<String>, stdio:Int, flags:Int):Null<ChildHandle>;

@:hlNative("haxeon_runtime", "__child_read_stdout")
internal extern function readStdout(child:ChildHandle, buffer:Bytes, offset:Int, length:Int):Int;

@:hlNative("haxeon_runtime", "__child_read_stderr")
internal extern function readStderr(child:ChildHandle, buffer:Bytes, offset:Int, length:Int):Int;

@:hlNative("haxeon_runtime", "__child_write")
internal extern function write(child:ChildHandle, buffer:Bytes, offset:Int, length:Int):Int;

@:hlNative("haxeon_runtime", "__child_close_stdin")
internal extern function closeStdin(child:ChildHandle):Void;

@:hlNative("haxeon_runtime", "__child_wait")
internal extern function wait(child:ChildHandle, wanted:Int, milliseconds:Int):Int;

@:hlNative("haxeon_runtime", "__child_exit_status")
internal extern function exitStatus(child:ChildHandle, out:Bytes):Bool;

@:hlNative("haxeon_runtime", "__child_pid")
internal extern function pid(child:ChildHandle):Int;

@:hlNative("haxeon_runtime", "__child_signal")
internal extern function signal(child:ChildHandle, force:Bool):Void;

@:hlNative("haxeon_runtime", "__child_close")
internal extern function close(child:ChildHandle):Void;

@:hlNative("haxeon_runtime", "__child_error")
internal extern function nativeError():Int;

@:hlNative("haxeon_runtime", "__child_error_code")
internal extern function nativeErrorCode():Int;

@:hlNative("haxeon_runtime", "__child_error_message")
internal extern function nativeErrorMessage():String;

/** Why the last native call on this thread failed. */
internal function lastError():ProcessError
	return switch nativeError() {
		case 1: NotFound;
		case 2: PermissionDenied;
		case 3: DirectoryNotFound;
		case 4: InputClosed;
		case 5: Unsupported;
		case _: Io(nativeErrorCode(), nativeErrorMessage());
	}

/** Seconds as the natives take them: negative waits without limit. */
internal function milliseconds(seconds:Float):Int
	return seconds < 0 ? -1 : seconds > 2147483 ? 2147483647 : Std.int(Math.ceil(seconds * 1000));

@:hlNative("haxeon_runtime", "__sys_monotonic_time")
internal extern function monotonicTime():Float;
