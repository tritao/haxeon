package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import std.process.ChildNatives;

/** What a child writes to its standard output or error, through a pipe: its `stdout` or `stderr`. */
class ChildOutput {
	final child:Child;
	final error:Bool;

	internal function new(child:Child, error:Bool) {
		this.child = child;
		this.error = error;
	}

	/**
	 * Reads up to `length` bytes into `buffer` from `offset` (by default to its end), waiting up to `timeoutSeconds`
	 * (negative: without limit; 0: not at all) for some to come: how many it read, which may be fewer than asked, and 0
	 * once the child has closed the stream. `TimedOut` when none came in time.
	 */
	public function read(buffer:Bytes, offset:Int = 0, length:Int = -1,
			timeoutSeconds:Float = -1):Result<Int, ProcessError> {
		var count = length < 0 ? buffer.length - offset : length;
		if (buffer == null || offset < 0 || count < 0 || offset > buffer.length - count)
			throw new haxe.Exception("std.process.ChildOutput: the range is outside the buffer");
		if (count == 0)
			return Ok(0);
		var deadline = timeoutSeconds < 0 ? -1.0 : now() + timeoutSeconds;
		while (true) {
			var handle = child.live();
			var got = error ? ChildNatives.readStderr(handle, buffer, offset, count) : ChildNatives.readStdout(handle,
				buffer,
				offset, count);
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

	/** Reads until the child closes the stream, and answers all of it. */
	public function readAll():Result<Bytes, ProcessError> {
		var chunk = Bytes.alloc(16384), all = new BytesBuffer();
		while (true) {
			var got = try read(chunk);
			if (got == 0)
				return Ok(all.getBytes());
			all.addBytes(chunk, 0, got);
		}
	}

	/** Reads until the child closes the stream, and answers it as UTF-8 text. */
	public function readText():Result<String, ProcessError> {
		var bytes = try readAll();
		return Ok(bytes.toString());
	}

	static inline function now():Float
		return ChildNatives.monotonicTime();
}
