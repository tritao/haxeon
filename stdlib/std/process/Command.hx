package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import std.fs.Path;
import std.process.ChildNatives;

/**
 * A program to run, set up before it starts: its arguments, working directory, environment and standard streams.
 * `spawn` starts it and answers the `Child`; `output` runs it to its end and answers what it wrote; `status` runs it
 * to its end with this program's streams. A command can be run any number of times.
 *
 * The program is found as the system finds it: a path, or a name looked up on the `PATH`. Its arguments reach it
 * exactly as given, each as one argument, with no shell in between (on Windows they are quoted into its command line
 * as the C runtime reads it). `Command.shell` runs a command line through the system's shell instead.
 */
class Command {
	final program:String;
	final arguments:Array<String> = [];
	var workingDirectory:Null<String> = null;
	final changedNames:Array<String> = [];
	final changedValues:Array<Null<String>> = [];
	var environmentCleared:Bool = false;
	var inputMode:Null<Stdio> = null;
	var outputMode:Null<Stdio> = null;
	var errorMode:Null<Stdio> = null;
	var startDetached:Bool = false;
	var ownGroup:Bool = false;
	var verbatim:Bool = false;

	/** The program `program`, with no arguments yet. */
	public function new(program:String) {
		if (program == null || program.length == 0)
			throw new haxe.Exception("std.process.Command: the program cannot be empty");
		this.program = program;
	}

	/**
	 * The command line `line`, run by the system's shell: `/bin/sh -c line` on POSIX, `cmd.exe /d /s /c "line"` on
	 * Windows (the shell `ComSpec` names). The shell reads its quoting, pipes and redirections, so `line` must not hold
	 * text from someone else unquoted.
	 */
	public static function shell(line:String):Command {
		if (Environment.namesIgnoreCase()) {
			var shell = Environment.variable("ComSpec");
			var command = new Command(shell == null || shell.length == 0 ? "cmd.exe" : shell);
			command.arguments.push('/d /s /c "$line"');
			command.verbatim = true;
			return command;
		}
		return new Command("/bin/sh").arg("-c").arg(line);
	}

	/** Adds `value` as the next argument. */
	public function arg(value:String):Command {
		if (value == null)
			throw new haxe.Exception("std.process.Command: an argument cannot be null");
		arguments.push(value);
		return this;
	}

	/** Adds each of `values` as the next arguments. */
	public function args(values:Array<String>):Command {
		for (value in values)
			arg(value);
		return this;
	}

	/** Starts the program in the directory `path`; `DirectoryNotFound` when it is not one. By default, this process's. */
	public function directory(path:Path):Command {
		workingDirectory = path.toString();
		return this;
	}

	/** Sets the environment variable `name` to `value` for the program, over what it inherits. */
	public function env(name:String, value:String):Command {
		if (value == null)
			throw new haxe.Exception('std.process.Command: the value of "$name" cannot be null');
		return change(name, value);
	}

	/** Leaves the environment variable `name` out of what the program inherits. */
	public function removeEnv(name:String):Command
		return change(name, null);

	/** Starts the program with no environment variables but those `env` sets afterwards. */
	public function clearEnv():Command {
		environmentCleared = true;
		changedNames.resize(0);
		changedValues.resize(0);
		return this;
	}

	/** What the program's standard input is. */
	public function stdin(stdio:Stdio):Command {
		inputMode = stdio;
		return this;
	}

	/** What the program's standard output is. */
	public function stdout(stdio:Stdio):Command {
		outputMode = stdio;
		return this;
	}

	/** What the program's standard error is. */
	public function stderr(stdio:Stdio):Command {
		errorMode = stdio;
		return this;
	}

	/**
	 * Lets the program outlive its `Child`: closing it, or this process exiting, leaves the program running. On Windows
	 * it also runs without a console window.
	 */
	public function detached(enabled:Bool = true):Command {
		startDetached = enabled;
		return this;
	}

	/**
	 * Starts the program in a process group of its own on POSIX, so `terminate`, `kill` and `close` reach what it
	 * starts as well (on Windows they always do). A program in its own group is not in the terminal's foreground: it
	 * should not read the terminal.
	 */
	public function group(enabled:Bool = true):Command {
		ownGroup = enabled;
		return this;
	}

	/** Starts the program; each stream not set otherwise is this program's own (`Inherit`). */
	public function spawn():Result<Child, ProcessError>
		return start(inputMode ?? Inherit, outputMode ?? Inherit, errorMode ?? Inherit);

	/**
	 * Runs the program to its end within `timeoutSeconds` (negative: without limit), and answers how it exited and what
	 * it wrote. Unless set otherwise, its output and error are piped to be read, and its input is empty (`Discard`).
	 * On `TimedOut` the program is ended.
	 */
	public function output(timeoutSeconds:Float = -1):Result<ProcessOutput, ProcessError> {
		scoped var child = try start(inputMode ?? Discard, outputMode ?? Pipe, errorMode ?? Pipe);
		return child.waitForOutput(timeoutSeconds);
	}

	/**
	 * Runs the program to its end within `timeoutSeconds` (negative: without limit), with this program's streams unless
	 * set otherwise, and answers how it exited. On `TimedOut` the program is ended.
	 */
	public function status(timeoutSeconds:Float = -1):Result<ExitStatus, ProcessError> {
		scoped var child = try start(inputMode ?? Inherit, outputMode ?? Inherit, errorMode ?? Inherit);
		return child.waitForOutput(timeoutSeconds).map(finished -> finished.status);
	}

	/** The program and its arguments, quoted as a POSIX shell would read them: for messages, not for running. */
	public function toString():String
		return [for (part in [program].concat(arguments)) quoted(part)].join(" ");

	function change(name:String, value:Null<String>):Command {
		if (!Environment.isName(name))
			throw new haxe.Exception('std.process.Command: "$name" is not a variable name');
		changedNames.push(name);
		changedValues.push(value);
		return this;
	}

	function start(stdinMode:Stdio, stdoutMode:Stdio, stderrMode:Stdio):Result<Child, ProcessError> {
		var keys:Array<String> = [], values:Array<String> = [];
		var replace = environment(keys, values);
		var flags = (startDetached ? (SpawnFlag.Detached:Int) : 0) | (ownGroup ? (SpawnFlag.Group:Int) : 0)
			| (verbatim ? (SpawnFlag.Verbatim:Int) : 0) | (replace ? (SpawnFlag.ReplaceEnvironment:Int) : 0);
		var stdio = stdinMode.getIndex() | (stdoutMode.getIndex() << 2) | (stderrMode.getIndex() << 4);
		var handle = ChildNatives.spawn(program, arguments, workingDirectory ?? "", keys, values, stdio, flags);
		return handle == null
			? Err(ChildNatives.lastError()) : Ok(new Child(handle, stdinMode, stdoutMode, stderrMode));
	}

	/**
	 * Fills `keys` and `values` with the program's environment: only the changes when it inherits the rest, or the
	 * whole of it (answering true) when variables are removed or cleared.
	 */
	function environment(keys:Array<String>, values:Array<String>):Bool {
		var removes = Lambda.exists(changedValues, value -> value == null);
		if (!environmentCleared && !removes) {
			for (index in 0...changedNames.length) {
				keys.push(changedNames[index]);
				values.push(changedValues[index] ?? "");
			}
			return false;
		}
		var whole = environmentCleared ? new Map<String, String>():Environment.variables();
		var ignoreCase = Environment.namesIgnoreCase();
		for (index in 0...changedNames.length) {
			var name = changedNames[index];
			if (ignoreCase)
				for (existing in [for (key in whole.keys()) key])
					if (existing.toLowerCase() == name.toLowerCase())
						whole.remove(existing);
			var value = changedValues[index];
			if (value == null)
				whole.remove(name);
			else
				whole.set(name, value);
		}
		for (name => value in whole) {
			keys.push(name);
			values.push(value);
		}
		return true;
	}

	static function quoted(part:String):String {
		for (index in 0...part.length) {
			var code = part.charCodeAt(index);
			var plain = (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code) || "-_./=:,+@%".indexOf(part.charAt(index)) >= 0;
			if (!plain)
				return "'" + part.split("'").join("'\\''") + "'";
		}
		return part.length == 0 ? "''" : part;
	}
}
