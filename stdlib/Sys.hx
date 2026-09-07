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
extern function sysTime():Float;

@:hlNative("std", "sys_cpu_time")
extern function sysCpuTime():Float;

@:hlNative("std", "sys_thread_cpu_time")
extern function sysThreadCpuTime():Float;

@:hlNative("std", "sys_process_memory")
extern function sysProcessMemory():Float;

@:hlNative("realtime_runtime", "__sys_get_cwd")
extern function sysGetCwd():String;

@:hlNative("realtime_runtime", "__sys_full_path")
extern function sysFullPath(path:String):String;

@:hlNative("realtime_runtime", "__sys_exe_path")
extern function sysExecutablePath():String;

@:hlNative("realtime_runtime", "__sys_get_env")
extern function sysGetEnv(name:String):Null<String>;

@:hlNative("realtime_runtime", "__sys_exists")
extern function sysExists(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_is_dir")
extern function sysIsDir(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_read_dir")
extern function sysReadDir(path:String):Array<String>;

@:hlNative("std", "sys_getpid")
extern function sysGetPid():Int;

@:hlNative("realtime_runtime", "__sys_args")
extern function sysArgs():Array<String>;

@:hlNative("realtime_runtime", "__sys_set_cwd")
extern function sysSetCwd(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_put_env")
extern function sysPutEnv(name:String, value:String):Bool;

@:hlNative("realtime_runtime", "__sys_create_dir")
extern function sysCreateDir(path:String, mode:Int):Bool;

@:hlNative("realtime_runtime", "__sys_remove_dir")
extern function sysRemoveDir(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_delete")
extern function sysDelete(path:String):Bool;

@:hlNative("realtime_runtime", "__sys_rename")
extern function sysRename(path:String, newPath:String):Bool;

@:hlNative("realtime_runtime", "__sys_command")
extern function sysCommand(command:String):Int;

@:hlNative("std", "sys_sleep")
extern function sysSleep(seconds:Float):Void;

@:hlNative("std", "sys_get_char")
extern function sysGetChar(echo:Bool):Int;

@:hlNative("realtime_runtime", "__sys_print")
extern function sysPrint(value:String):Void;

/** Supported host and process operations exposed through HashLink. */
class Sys {
	public static inline function time():Float
		return sysTime();

	public static inline function cpuTime():Float
		return sysCpuTime();

	public static inline function threadCpuTime():Float
		return sysThreadCpuTime();

	public static inline function processMemory():Float
		return sysProcessMemory();

	public static inline function getCwd():String
		return sysGetCwd();

	public static inline function fullPath(path:String):String
		return sysFullPath(path);

	public static inline function executablePath():String
		return sysExecutablePath();

	public static inline function getEnv(name:String):Null<String>
		return sysGetEnv(name);

	public static inline function exists(path:String):Bool
		return sysExists(path);

	public static inline function isDir(path:String):Bool
		return sysIsDir(path);

	public static inline function readDir(path:String):Array<String>
		return sysReadDir(path);

	public static inline function getPid():Int
		return sysGetPid();

	public static inline function args():Array<String>
		return sysArgs();

	public static inline function setCwd(path:String):Bool
		return sysSetCwd(path);

	public static inline function putEnv(name:String, value:String):Bool
		return sysPutEnv(name, value);

	public static inline function createDir(path:String, mode:Int):Bool
		return sysCreateDir(path, mode);

	public static inline function removeDir(path:String):Bool
		return sysRemoveDir(path);

	public static inline function delete(path:String):Bool
		return sysDelete(path);

	public static inline function rename(path:String, newPath:String):Bool
		return sysRename(path, newPath);

	public static inline function command(command:String):Int
		return sysCommand(command);

	public static inline function sleep(seconds:Float):Void
		sysSleep(seconds);

	public static inline function getChar(echo:Bool):Int
		return sysGetChar(echo);

	public static inline function println(value:String):Void
		sysPrint(value);
}
