package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module has no process environment of its own"
#end
import std.fs.Path;

@:hlNative("haxeon_runtime", "__sys_args")
internal extern function nativeArguments():Array<String>;

@:hlNative("haxeon_runtime", "__sys_get_env")
internal extern function nativeVariable(name:String):Null<String>;

@:hlNative("haxeon_runtime", "__sys_environment")
internal extern function nativeVariables():Array<String>;

@:hlNative("haxeon_runtime", "__sys_put_env")
internal extern function nativeSetVariable(name:String, value:Null<String>):Bool;

@:hlNative("haxeon_runtime", "__sys_exe_path")
internal extern function nativeExecutablePath():String;

@:hlNative("haxeon_runtime", "__sys_program_path")
internal extern function nativeProgramPath():String;

@:hlNative("haxeon_runtime", "__sys_system_name")
internal extern function nativeSystemName():String;

@:hlNative("std", "sys_getpid")
internal extern function nativeId():Int;

@:hlNative("std", "sys_exit")
internal extern function nativeExit(code:Int):Void;

/**
 * This process: the arguments it was started with, its environment variables (which the children it starts inherit),
 * its executable and its id. The working directory is `std.fs.Files.workingDirectory`.
 */
class Environment {
	/** The arguments the program was started with, without the program's own path. */
	public static function arguments():Array<String>
		return nativeArguments();

	/** The value of the environment variable `name`, or null when it is not set. */
	public static function variable(name:String):Null<String>
		return nativeVariable(checkedName(name));

	/** Every environment variable, by name. */
	public static function variables():Map<String, String> {
		var result:Map<String, String> = [];
		for (entry in nativeVariables()) {
			// A Windows entry such as "=C:" (a drive's directory) starts with its separator; it is not a variable.
			var separator = entry.indexOf("=", 1);
			if (separator > 0)
				result.set(entry.substr(0, separator), entry.substr(separator + 1));
		}
		return result;
	}

	/** Sets the environment variable `name` to `value`, for this process and the children it starts from now on. */
	public static function setVariable(name:String, value:String):Void {
		if (value == null)
			throw new haxe.Exception('std.process.Environment: the value of "$name" is null');
		if (!nativeSetVariable(checkedName(name), value))
			throw new haxe.Exception('std.process.Environment: "$name" could not be set');
	}

	/** Removes the environment variable `name`; removing one that is not set does nothing. */
	public static function removeVariable(name:String):Void
		if (!nativeSetVariable(checkedName(name), null))
			throw new haxe.Exception('std.process.Environment: "$name" could not be removed');

	/** The path of the program's executable (the HashLink VM, for a program it runs). */
	public static function executablePath():Path
		return Path.of(nativeExecutablePath());

	/**
	 * The program that runs: its `.hl` module on the HashLink VM, or the executable a program compiled ahead of time is.
	 * Starting `executablePath()` with it (when the two differ) runs the program again.
	 */
	public static function programPath():Path
		return Path.of(nativeProgramPath());

	/** The process's id. */
	public static function id():Int
		return nativeId();

	/** Ends the process with exit code `code`, without returning. */
	public static function exit(code:Int):Void
		nativeExit(code);

	/** Whether variable names are compared ignoring case, as on Windows. */
	internal static function namesIgnoreCase():Bool
		return nativeSystemName() == "Windows";

	static function checkedName(name:String):String {
		if (name == null || name.length == 0 || name.indexOf("=") >= 0)
			throw new haxe.Exception('std.process.Environment: "$name" is not a variable name');
		return name;
	}
}
