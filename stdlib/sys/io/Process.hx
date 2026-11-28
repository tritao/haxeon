package sys.io;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;

#if wasm
/** Haxe's Process: a Wasm module cannot start processes. */
class Process {
	/** The child's standard output, to read. */
	public var stdout(default, null):haxe.io.Input;

	/** The child's standard error, to read. */
	public var stderr(default, null):haxe.io.Input;

	/** The child's standard input, to write; close it to let the child read its end. */
	public var stdin(default, null):haxe.io.Output;

	/**
	 * Starts `cmd`. Without `args` the command line goes to the shell; with them `cmd` runs directly with exactly those
	 * arguments (on Windows they are quoted into the command line, as Haxe does).
	 */
	public function new(cmd:String, ?args:Array<String>, ?detached:Bool)
		throw "Processes are not available on Wasm";

	/** The child's process id. */
	public function getPid():Int
		throw "Processes are not available on Wasm";

	/** The exit code; with `block` false, null while the child still runs. */
	public function exitCode(block:Bool = true):Null<Int>
		throw "Processes are not available on Wasm";

	/** Releases the pipes and the process handle; the child keeps running. */
	public function close():Void {}

	/** Ends the child at once (SIGKILL, or TerminateProcess on Windows), without letting it clean up. */
	public function kill():Void {}
}
#else
import std.process.Child;
import std.process.ChildInput;
import std.process.ChildOutput;
import std.process.Command;

/** What the child writes to its standard output or error; the end of the input once it closes the stream. */
private class ProcessOutput extends haxe.io.Input {
	final stream:ChildOutput;
	final single = Bytes.alloc(1);

	public function new(stream:ChildOutput)
		this.stream = stream;

	override public function readByte():Int {
		readBytes(single, 0, 1);
		return single.get(0);
	}

	override public function readBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		if (len == 0)
			return 0;
		var count = readChunk(s, pos, len);
		if (count == 0)
			throw new Eof();
		return count;
	}

	/** EOF is the normal stop condition here, so there is no exception stack to capture. */
	override public function readAll(?bufsize:Int):Bytes {
		var size = bufsize == null ? 1 << 14 : bufsize,
			buffer = Bytes.alloc(size),
			total = new BytesBuffer();
		if (size == 0)
			throw haxe.io.Error.Blocked;
		while (true) {
			var count = readChunk(buffer, 0, size);
			if (count == 0)
				return total.getBytes();
			total.addBytes(buffer, 0, count);
		}
	}

	function readChunk(bytes:Bytes, pos:Int, len:Int):Int
		return switch stream.read(bytes, pos, len) {
			case Ok(count): count;
			case Err(error): throw haxe.io.Error.Custom(error.describe());
		}
}

/** What the program writes to the child's standard input. */
private class ProcessInput extends haxe.io.Output {
	final stream:ChildInput;
	final single = Bytes.alloc(1);

	public function new(stream:ChildInput)
		this.stream = stream;

	override public function writeByte(c:Int):Void {
		single.set(0, c);
		writeBytes(single, 0, 1);
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > s.length)
			throw haxe.io.Error.OutsideBounds;
		return switch stream.write(s, pos, len) {
			case Ok(_): len;
			case Err(InputClosed): throw new Eof();
			case Err(error): throw haxe.io.Error.Custom(error.describe());
		}
	}

	/** Closes the child's standard input, so it sees the end of its input. */
	override public function close():Void
		stream.close();
}

/**
 * A child process, as Haxe's sys.io.Process, over `std.process`, which new code uses directly: a `Command` sets up its
 * environment, directory and streams, and its failures are values.
 */
class Process {
	final child:Child;

	/** The child's standard output, to read. */
	public var stdout(default, null):haxe.io.Input;

	/** The child's standard error, to read. */
	public var stderr(default, null):haxe.io.Input;

	/** The child's standard input, to write; close it to let the child read its end. */
	public var stdin(default, null):haxe.io.Output;

	/**
	 * Starts `cmd`. Without `args` the command line goes to the system's shell (`Command.shell`); with them `cmd` runs
	 * directly with exactly those arguments. Throws when the program cannot be started.
	 */
	public function new(cmd:String, ?args:Array<String>, ?detached:Bool) {
		var command = args == null ? Command.shell(cmd) : new Command(cmd).args(args);
		command.stdin(Pipe).stdout(Pipe).stderr(Pipe).detached(detached == true);
		child = switch command.spawn() {
			case Ok(started): started;
			case Err(error): throw 'Process creation failure : $cmd: ${error.describe()}';
		};
		var output = child.stdout, error = child.stderr, input = child.stdin;
		if (output == null || error == null || input == null)
			throw "Process creation failure : the streams were not piped";
		stdout = new ProcessOutput(output);
		stderr = new ProcessOutput(error);
		stdin = new ProcessInput(input);
	}

	/** The child's process id. */
	public function getPid():Int
		return child.pid;

	/** The exit code (128 plus the signal for a child a signal ended); with `block` false, null while it still runs. */
	public function exitCode(block:Bool = true):Null<Int> {
		var status = block ? switch child.wait() {
			case Ok(exited): exited;
			case Err(error): throw "Process wait failure : " + error.describe();
		} : child.exitStatus();
		return switch status {
			case null: null;
			case Exited(code): code;
			case Signaled(signal): 128 + signal;
		}
	}

	/** Releases the pipes and the process handle, ending the child if it still runs (unless it was started detached). */
	public function close():Void
		child.close();

	/** Ends the child at once (SIGKILL, or TerminateProcess on Windows), without letting it clean up. */
	public function kill():Void
		child.kill();
}
#end
