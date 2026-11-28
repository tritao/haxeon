package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import std.bytes.Bytes;
import std.io.Reader;
import std.process.ChildNatives;

/**
 * What a child writes to its standard output or error, through a pipe: its `stdout` or `stderr`, a `Reader` whose reads
 * wait as long as it takes; `readWithin` gives up after a timeout.
 */
class ChildOutput extends Reader<ProcessError> {
	final child:Child;
	final error:Bool;

	internal function new(child:Child, error:Bool) {
		this.child = child;
		this.error = error;
	}

	function readRange(buffer:Bytes, offset:Int, length:Int):Result<Int, ProcessError>
		return readWithin(-1, buffer, offset, length);

	/**
	 * Reads up to `length` bytes into `buffer` from `offset` (by default to its end), waiting up to `timeoutSeconds`
	 * (negative: without limit; 0: not at all) for some to come: how many it read, which may be fewer than asked, and 0
	 * once the child has closed the stream. `TimedOut` when none came in time.
	 */
	public function readWithin(timeoutSeconds:Float, buffer:Bytes, offset:Int = 0,
			length:Int = -1):Result<Int, ProcessError> {
		var count = length < 0 ? buffer.length - offset : length;
		if (buffer == null || offset < 0 || count < 0 || offset > buffer.length - count)
			throw new haxe.Exception("std.process.ChildOutput: the range is outside the buffer");
		if (count == 0)
			return Ok(0);
		var deadline = timeoutSeconds < 0 ? -1.0 : now() + timeoutSeconds;
		while (true) {
			var handle = child.live();
			var got = error ? ChildNatives.readStderr(handle, buffer, offset, count) : ChildNatives.readStdout(handle,
				buffer, offset, count);
			if (got > 0)
				return Ok(got);
			if (got == -1)
				return Ok(0);
			if (got == -3)
				return Err(ChildNatives.lastError());
			var left = deadline < 0 ? -1.0 : deadline - now();
			if (deadline >= 0 && left <= 0)
				return Err(TimedOut);
			var ready = ChildNatives.wait(handle, error ? Readiness.Stderr : Readiness.Stdout,
				ChildNatives.milliseconds(left));
			if (ready < 0)
				return Err(ChildNatives.lastError());
			if (ready == 0)
				return Err(TimedOut);
		}
	}

	static inline function now():Float
		return ChildNatives.monotonicTime();
}
