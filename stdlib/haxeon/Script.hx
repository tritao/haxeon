package haxeon;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Output;
import haxe.io.Path;
import std.process.Child;
import std.process.Command;
import sys.FileSystem;
import sys.io.File;

/** How `Script.run` starts a program. */
typedef ScriptRunOptions = {
	/** The program's working directory; the script's own by default. */
	var ?cwd:String;

	/** Variables set for the program, over those it inherits. */
	var ?env:Map<String, String>;

	/** A file that receives the program's standard output and error, instead of passing them through. */
	var ?log:String;

	/** Seconds after which the program is asked to stop; its status is then 124, as coreutils' `timeout` answers. */
	var ?timeout:Float;
}

/** One program for `Script.runAll`: what `Script.run` takes. */
typedef ScriptJob = {
	final command:String;
	final ?arguments:Array<String>;
	final ?options:ScriptRunOptions;
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
	public static function run(command:String, ?arguments:Array<String>, ?options:ScriptRunOptions):Int
		return runAll([{command: command, arguments: arguments, options: options}], 1)[0];

	/**
	 * Runs `jobs` with up to `parallel` at a time and returns their exit statuses, in their order. Each one's output goes to
	 * its `options.log`, or passes through, interleaved with the others', without one.
	 */
	public static function runAll(jobs:Array<ScriptJob>, parallel:Int):Array<Int> {
		var statuses = [for (_ in jobs) -1], running:Array<{index:Int, program:RunningProgram}> = [], next = 0;
		try {
			while (next < jobs.length || running.length > 0) {
				while (running.length < (parallel < 1 ? 1 : parallel) && next < jobs.length) {
					var job = jobs[next];
					running.push({index: next, program: new RunningProgram(job.command, job.arguments, job.options)});
					next++;
				}
				var moved = false;
				for (entry in running.copy())
					if (entry.program.step())
						moved = true;
					else {
						var status = entry.program.exitStatus();
						if (status >= 0) {
							statuses[entry.index] = status;
							entry.program.close();
							running.remove(entry);
							moved = true;
						}
					}
				if (!moved)
					Sys.sleep(0.002);
			}
		} catch (error:Dynamic) {
			for (entry in running)
				entry.program.close();
			throw error;
		}
		return statuses;
	}

	/** How many programs a script runs at once: `TEST_JOBS`, or `fallback`. */
	public static function jobs(fallback:Int):Int {
		var configured = Sys.getEnv("TEST_JOBS"), parsed = configured == null ? null : Std.parseInt(configured);
		return parsed == null || parsed < 1 ? fallback : parsed;
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
			status = new RunningProgram(command, arguments, options, captured).finish(),
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

/**
 * A started program whose two pipes are copied as they produce: to `options.log`, to `out` for standard output when given,
 * or through to the script's own.
 */
private class RunningProgram {
	final process:Child;
	final log:Null<Output>;
	final out:Output;
	final err:Output;
	final buffer = Bytes.alloc(65536);
	final deadline:Float;
	var outOpen = true;
	var errOpen = true;
	var timedOut = false;

	public function new(command:String, arguments:Null<Array<String>>, options:Null<ScriptRunOptions>, ?out:Output) {
		// Its own group, so stopping it at its deadline stops what it started too; no input, so it never waits for any.
		var launch = new Command(command).args(arguments == null ? [] : arguments).stdin(Discard).stdout(Pipe)
			.stderr(Pipe).group();
		if (options != null && options.cwd != null)
			launch.directory(options.cwd);
		if (options != null && options.env != null)
			for (key => value in options.env)
				launch.env(key, value);
		var logFile = options == null || options.log == null ? null : File.write(options.log, true);
		log = logFile;
		this.out = out != null ? out : logFile != null ? logFile : Sys.stdout();
		err = logFile != null ? logFile : Sys.stderr();
		var timeout = options == null ? null : options.timeout;
		deadline = timeout == null ? Math.POSITIVE_INFINITY : Sys.time() + timeout;
		process = switch launch.spawn() {
			case Ok(started): started;
			case Err(error):
				if (logFile != null)
					logFile.close();
				throw '$launch could not be started: ${error.describe()}';
		};
	}

	/** Copies what the pipes have ready; whether anything moved. False once both are drained. */
	public function step():Bool {
		if (!timedOut && Sys.time() >= deadline) {
			timedOut = true;
			process.terminate();
		}
		var moved = false;
		if (outOpen)
			switch copy(process.stdout, out) {
				case 0: outOpen = false;
				case -1:
				case _: moved = true;
			}
		if (errOpen)
			switch copy(process.stderr, err) {
				case 0: errOpen = false;
				case -1:
				case _: moved = true;
			}
		return moved;
	}

	/** Copies what `stream` has ready to `target`: how many bytes, 0 at its end, -1 when none were ready. */
	function copy(stream:Null<std.process.ChildOutput>, target:Output):Int {
		if (stream == null)
			return 0;
		return switch stream.read(buffer, 0, buffer.length, 0) {
			case Ok(0): 0;
			case Ok(read):
				target.writeBytes(buffer, 0, read);
				target.flush();
				read;
			case Err(TimedOut): -1;
			case Err(error): throw 'reading a program\'s output failed: ${error.describe()}';
		}
	}

	/** The exit status once both pipes are drained and the program has exited, else -1; 124 when it was stopped at its deadline. */
	public function exitStatus():Int {
		if (outOpen || errOpen)
			return -1;
		var status = switch process.exitStatus() {
			case null: -1;
			case Exited(code): code;
			case Signaled(signal): 128 + signal;
		};
		return status >= 0 && timedOut ? 124 : status;
	}

	/** Copies the pipes until the program exits, closes it and returns its status. */
	public function finish():Int {
		try {
			var status = -1;
			while (status < 0) {
				if (!step())
					Sys.sleep(0.002);
				status = exitStatus();
			}
			close();
			return status;
		} catch (error:Dynamic) {
			close();
			throw error;
		}
	}

	/** Releases the program and closes its log. */
	public function close():Void {
		process.close();
		out.flush();
		err.flush();
		if (log != null)
			log.close();
	}
}
