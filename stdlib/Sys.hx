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

@:hlNative("std", "sys_get_cwd")
extern function sysGetCwd():String;

@:hlNative("std", "sys_full_path")
extern function sysFullPath(path:String):String;

@:hlNative("std", "sys_exe_path")
extern function sysExecutablePath():String;

@:hlNative("std", "sys_get_env")
extern function sysGetEnv(name:String):Null<String>;

@:hlNative("std", "sys_exists")
extern function sysExists(path:String):Bool;

@:hlNative("std", "sys_is_dir")
extern function sysIsDir(path:String):Bool;

@:hlNative("std", "sys_read_dir")
extern function sysReadDir(path:String):Array<String>;

@:hlNative("std", "sys_getpid")
extern function sysGetPid():Int;

@:hlNative("realtime_runtime", "__sys_args")
extern function sysArgs():Array<String>;

/** Read-only host and process information exposed through HashLink. */
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
}
