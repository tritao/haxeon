/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */
@:hlNative("std", "sys_time")
internal extern function sysTime():Float;

@:hlNative("haxeon_runtime", "__sys_monotonic_time")
internal extern function sysMonotonicTime():Float;

@:hlNative("std", "sys_cpu_time")
internal extern function sysCpuTime():Float;

@:hlNative("std", "sys_thread_cpu_time")
internal extern function sysThreadCpuTime():Float;

@:hlNative("std", "sys_process_memory")
internal extern function sysProcessMemory():Float;

#if !wasm
@:hlNative("haxeon_runtime", "__sys_get_cwd")
internal extern function sysGetCwd():String;

/** std.fs's native, bound here too so a program that uses Sys does not load std.fs. */
@:hlNative("haxeon_runtime", "__fs_absolute")
internal extern function sysFullPath(path:String):String;

@:hlNative("haxeon_runtime", "__sys_exe_path")
internal extern function sysExecutablePath():String;

@:hlNative("haxeon_runtime", "__sys_program_path")
internal extern function sysProgramPath():String;

@:hlNative("haxeon_runtime", "__sys_get_env")
internal extern function sysGetEnv(name:String):Null<String>;

@:hlNative("haxeon_runtime", "__sys_environment")
internal extern function sysEnvironment():Array<String>;

@:hlNative("haxeon_runtime", "__sys_system_name")
internal extern function sysSystemName():String;
#else
// Wasm has no host process: the path operations use the session's in-memory filesystem, the
// environment is empty, and there is no executable path.
internal function sysGetCwd():String
	return runtime.MemoryFileSystem.getCwd();

internal function sysFullPath(path:String):String
	return runtime.MemoryFileSystem.normalize(path);

internal function sysExecutablePath():String
	return "";

internal function sysProgramPath():String
	return "";

internal function sysGetEnv(name:String):Null<String>
	return null;

internal function sysEnvironment():Array<String>
	return [];

internal function sysSystemName():String
	return "Web";
#end

@:hlNative("std", "sys_getpid")
internal extern function sysGetPid():Int;

@:hlNative("std", "sys_exit")
internal extern function sysExit(code:Int):Void;

#if wasmgc
// The host's arguments are strings in linear memory, which a Wasm GC program does not have.
internal function sysArgs():Array<String>
	return [];
#elseif wasm
internal function sysArgs():Array<String>
	return [for (index in 0...haxeon.wasm.HaxeonHost.argument_count()) haxeon.wasm.HaxeonHost.argument(index)];
#else
@:hlNative("haxeon_runtime", "__sys_args")
internal extern function sysArgs():Array<String>;
#end

#if !wasm
@:hlNative("haxeon_runtime", "__sys_set_cwd")
internal extern function sysSetCwd(path:String):Bool;
#else
internal function sysSetCwd(path:String):Bool
	return runtime.MemoryFileSystem.setCwd(path);
#end

@:hlNative("haxeon_runtime", "__sys_put_env")
internal extern function sysPutEnv(name:String, value:String):Bool;

@:hlNative("haxeon_runtime", "__sys_command")
internal extern function sysCommand(command:String):Int;

@:hlNative("std", "sys_sleep")
internal extern function sysSleep(seconds:Float):Void;

@:hlNative("std", "sys_get_char")
internal extern function sysGetChar(echo:Bool):Int;

#if wasm
internal function sysPrint(value:String):Void
	haxeon.wasm.HaxeonHost.print(value);
#else
@:hlNative("haxeon_runtime", "__sys_print")
internal extern function sysPrint(value:String):Void;
#end

#if wasm
internal function sysStdout():sys.io.FileOutput
	return sys.io.FileOutput.host(false);

internal function sysStderr():sys.io.FileOutput
	return sys.io.FileOutput.host(true);
#else
@:hlNative("haxeon_runtime", "__sys_stdout")
internal extern function sysStdoutHandle():hl.Abstract<"realtime_file_output">;

@:hlNative("haxeon_runtime", "__sys_stderr")
internal extern function sysStderrHandle():hl.Abstract<"realtime_file_output">;

internal function sysStdout():sys.io.FileOutput
	return new sys.io.FileOutput(sysStdoutHandle());

internal function sysStderr():sys.io.FileOutput
	return new sys.io.FileOutput(sysStderrHandle());

@:hlNative("haxeon_runtime", "__sys_stdin")
internal extern function sysStdinHandle():hl.Abstract<"realtime_file_input">;
#end

/** The process and its host: time, environment, files and directories, the console, and running commands. */
class Sys {
	/**
	 * The current time, in seconds since the Unix epoch, with a fractional part. It follows the system clock, which can
	 * jump: measure elapsed time with `monotonicTime`.
	 */
	public static inline function time():Float
		return sysTime();

	/** Monotonic seconds from an unspecified epoch, for elapsed time and deadlines. */
	public static inline function monotonicTime():Float
		return sysMonotonicTime();

	/** The CPU time the process has used, user and system, in seconds. */
	public static inline function cpuTime():Float
		return sysCpuTime();

	/** The CPU time the calling thread has used, in seconds. */
	public static inline function threadCpuTime():Float
		return sysThreadCpuTime();

	/**
	 * The process's resident memory (its working set), in bytes, on Windows; 0 on the other platforms, which do not
	 * report it.
	 */
	public static inline function processMemory():Float
		return sysProcessMemory();

	/** The working directory, as an absolute path. On Wasm it is the session's in-memory filesystem's. */
	public static inline function getCwd():String
		return sysGetCwd();

	/** `path` as an absolute, normalized path, resolved against the working directory. */
	public static inline function fullPath(path:String):String
		return sysFullPath(path);

	/** Path of the loaded program (the .hl module on HashLink). */
	public static inline function programPath():String
		return sysProgramPath();

	/**
	 * The path of the executable running the program: the VM on HashLink, the app's own executable when it embeds one.
	 * Empty on Wasm.
	 */
	public static inline function executablePath():String
		return sysExecutablePath();

	/**
	 * The value of the environment variable `name`, or null when it is not set. Always null on Wasm, which has no
	 * environment.
	 */
	public static inline function getEnv(name:String):Null<String>
		return sysGetEnv(name);

	/** Returns a snapshot of the host process environment. */
	public static function environment():Map<String, String> {
		var result:Map<String, String> = new Map();
		for (entry in sysEnvironment()) {
			var separator = entry.indexOf("=");
			if (separator > 0)
				result.set(entry.substr(0, separator), entry.substr(separator + 1));
		}
		return result;
	}

	/**
	 * The operating system: `"Windows"`, `"Mac"` (iOS too), `"Linux"` (Android too), `"BSD"`, or `"Unknown"`; `"Web"` on
	 * Wasm.
	 */
	public static inline function systemName():String
		return sysSystemName();

	/** The process's id. */
	public static inline function getPid():Int
		return sysGetPid();

	/** Ends the process with an exit code, without returning. */
	public static inline function exit(code:Int):Void
		sysExit(code);

	/** The arguments the program was started with, without the program's own path. */
	public static inline function args():Array<String>
		return sysArgs();

	/** Makes `path` the working directory. Returns whether it could. */
	public static inline function setCwd(path:String):Bool
		return sysSetCwd(path);

	/**
	 * Sets the environment variable `name` to `value` for this process and those it starts. Returns whether it could.
	 */
	public static inline function putEnv(name:String, value:String):Bool
		return sysPutEnv(name, value);

	/**
	 * Runs `command` through the system's shell and waits for it, returning its exit code. Each of `args` is quoted for
	 * the shell, so it reaches the command as one argument; without them, `command` is passed to the shell as written.
	 * `sys.io.Process` runs a program without a shell and reads its output.
	 */
	public static function command(command:String, ?args:Array<String>):Int {
		if (args == null || args.length == 0)
			return sysCommand(command);
		var windows = systemName() == "Windows";
		var parts = [command];
		for (argument in args)
			parts.push(quoteCommandArgument(argument, windows));
		return sysCommand(parts.join(" "));
	}

	static function quoteCommandArgument(value:String, windows:Bool):String {
		var argument = value == null ? "" : value;
		if (windows)
			return "\"" + argument.split("\"").join("\\\"") + "\"";
		return "'" + argument.split("'").join("'\\''") + "'";
	}

	/** Suspends the calling thread for `seconds`. */
	public static inline function sleep(seconds:Float):Void
		sysSleep(seconds);

	/**
	 * Reads one character from the terminal without waiting for a line, echoing it when `echo` is true, and returns its
	 * code.
	 */
	public static inline function getChar(echo:Bool):Int
		return sysGetChar(echo);

	/** Writes `value`, as `Std.string` gives it, to the standard output. */
	public static inline function print(value:Dynamic):Void
		sysPrint(Std.string(value));

	/** Writes `value`, as `Std.string` gives it, and a newline to the standard output. */
	public static inline function println(value:Dynamic):Void
		sysPrint(Std.string(value) + "\n");

	/** The standard output, to write to as a stream. */
	public static inline function stdout():sys.io.FileOutput
		return sysStdout();

	/** The standard error output, to write to as a stream. */
	public static inline function stderr():sys.io.FileOutput
		return sysStderr();

	/** The standard input, to read from as a stream. */
	public static function stdin():sys.io.FileInput {
		#if wasm
		return new sys.io.FileInput();
		#else
		return new sys.io.FileInput(sysStdinHandle());
		#end
	}
}
