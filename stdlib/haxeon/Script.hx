package haxeon;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Output;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.ChildProcess;
import sys.io.File;

/** How `Script.run` starts a program. */
typedef ScriptRunOptions = {
	/** The program's working directory; the script's own by default. */
	var ?cwd:String;

	/** Variables set for the program, over those it inherits. */
	var ?env:Map<String, String>;

	/** A file that receives the program's standard output and error, instead of passing them through. */
	var ?log:String;
}

/**
 * What shell scripts make short, for Haxe scripts run with `haxeon script.hx` (tools.ScriptRun): running programs and
 * checking their status, capturing their output, and the small file chores around them. Programs are started directly, never
 * through a shell, so arguments need no quoting and a script runs the same on every platform.
 */
class Script {
	/** The running script's file: `haxeon script.hx` names it in HAXEON_SCRIPT. */
	public static function path():String {
		var value = Sys.getEnv("HAXEON_SCRIPT");
		if (value == null || value == "")
			fail("haxeon.Script.path(): not running as a script (haxeon script.hx)");
		return value;
	}

	/** The directory of the running script's file. */
	public static function directory():String
		return Path.directory(path());

	/** The HashLink VM that runs scripts, from the haxeon command that started this one. */
	public static function vm():String
		return program("hl");

	/** The haxeon command that started this script. */
	public static function haxeon():String
		return program("haxeon");

	/** Runs `command` and returns its exit status. Its output passes through, or goes to `options.log`. */
	public static function run(command:String, ?arguments:Array<String>, ?options:ScriptRunOptions):Int {
		var log = options == null || options.log == null ? null : File.write(options.log, true);
		try {
			var status = pump(command, arguments, options, log == null ? Sys.stdout() : log,
				log == null ? Sys.stderr() : log);
			if (log != null)
				log.close();
			return status;
		} catch (error:Dynamic) {
			if (log != null)
				log.close();
			throw error;
		}
	}

	/** As `run`, and stops the script when the status is not 0. */
	public static function check(command:String, ?arguments:Array<String>, ?options:ScriptRunOptions):Void {
		var status = run(command, arguments, options);
		if (status != 0)
			fail('${describe(command, arguments)} exited with status $status'
				+ (options != null && options.log != null ? '; its output is in ${options.log}' : ""));
	}

	/** Runs `command` and returns its standard output; its standard error passes through. Stops the script on a status other than 0. */
	public static function output(command:String, ?arguments:Array<String>, ?options:ScriptRunOptions):String {
		var captured = new BytesOutput(),
			status = pump(command, arguments, options, captured, Sys.stderr()),
			text = captured.getBytes().toString();
		if (status != 0)
			fail('${describe(command, arguments)} exited with status $status');
		return StringTools.endsWith(text, "\n") ? text.substr(0,
			text.length - (StringTools.endsWith(text, "\r\n") ? 2 : 1)) : text;
	}

	/** Prints `message` to standard error and ends the script with `status`. */
	public static function fail(message:String, status:Int = 1):Void {
		Sys.stderr().writeString(message + "\n");
		Sys.stderr().flush();
		Sys.exit(status);
	}

	/** The last `count` lines of a text file, or nothing when it does not exist. */
	public static function tail(file:String, count:Int):String {
		if (!FileSystem.exists(file))
			return "";
		var lines = File.getContent(file).split("\n");
		if (lines.length > 0 && lines[lines.length - 1] == "")
			lines.pop();
		return lines.slice(lines.length > count ? lines.length - count : 0).join("\n");
	}

	/** The files under `directory` whose names end in `suffix`, as paths relative to it with `/`, sorted by their bytes. */
	public static function files(directory:String, suffix:String):Array<String> {
		var result = [];
		collect(directory, "", suffix, result);
		result.sort((left, right) -> left < right ? -1 : left > right ? 1 : 0);
		return result;
	}

	/** Whether two files exist and have the same bytes. */
	public static function sameContent(left:String, right:String):Bool
		return FileSystem.exists(left) && FileSystem.exists(right)
			&& File.getBytes(left).compare(File.getBytes(right)) == 0;

	static function collect(directory:String, prefix:String, suffix:String, result:Array<String>):Void {
		for (name in FileSystem.readDirectory(directory)) {
			var full = Path.join([directory, name]), relative = prefix == "" ? name : prefix + "/" + name;
			if (FileSystem.isDirectory(full))
				collect(full, relative, suffix, result);
			else if (StringTools.endsWith(name, suffix))
				result.push(relative);
		}
	}

	/** Starts the program and copies its two pipes to `out` and `err` as they produce, until it exits and both are drained. */
	static function pump(command:String, arguments:Null<Array<String>>, options:Null<ScriptRunOptions>, out:Output,
			err:Output):Int {
		var keys:Array<String> = [], values:Array<String> = [];
		if (options != null && options.env != null)
			for (key => value in options.env) {
				keys.push(key);
				values.push(value);
			}
		var cwd = options == null || options.cwd == null ? "" : options.cwd,
			process = ChildProcess.spawn(command, arguments == null ? [] : arguments, cwd, keys, values),
			buffer = Bytes.alloc(65536),
			outOpen = true,
			errOpen = true;
		try {
			while (outOpen || errOpen) {
				var moved = false;
				if (outOpen) {
					var read = process.readStdout(buffer, 0, buffer.length);
					if (read > 0) {
						out.writeBytes(buffer, 0, read);
						out.flush();
						moved = true;
					} else if (read == -1)
						outOpen = false;
				}
				if (errOpen) {
					var read = process.readStderr(buffer, 0, buffer.length);
					if (read > 0) {
						err.writeBytes(buffer, 0, read);
						err.flush();
						moved = true;
					} else if (read == -1)
						errOpen = false;
				}
				if (!moved && (outOpen || errOpen))
					Sys.sleep(0.002);
			}
			var status = process.pollExit();
			while (status < 0) {
				Sys.sleep(0.002);
				status = process.pollExit();
			}
			out.flush();
			err.flush();
			process.close();
			return status;
		} catch (error:Dynamic) {
			process.close();
			throw error;
		}
	}

	/** A program in the bin of the SDK of the haxeon command that started this script (`HAXEON_SDK`). */
	static function program(name:String):String {
		var sdk = Sys.getEnv("HAXEON_SDK");
		if (sdk == null || sdk == "")
			fail('haxeon.Script: HAXEON_SDK is not set; run the script with haxeon');
		return Path.join([sdk, "bin", Sys.systemName() == "Windows" ? name + ".exe" : name]);
	}

	static function describe(command:String, arguments:Null<Array<String>>):String
		return [command].concat(arguments == null ? [] : arguments).join(" ");
}
