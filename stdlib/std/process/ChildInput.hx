package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import std.bytes.Bytes;
import std.io.Writer;
import std.process.ChildNatives;

/** What this program writes to a child's standard input, through a pipe: its `stdin`, a `Writer`. */
class ChildInput extends Writer<ProcessError> {
	final child:Child;
	var closed:Bool = false;

	internal function new(child:Child)
		this.child = child;

	/**
	 * Writes the range, waiting while the pipe is full, until the child has been given every byte of it. `InputClosed` when
	 * it no longer reads.
	 */
	function writeRange(buffer:Bytes, offset:Int, count:Int):Result<Void, ProcessError> {
		if (closed)
			throw new haxe.Exception("std.process.ChildInput is closed");
		var at = offset, end = offset + count;
		while (at < end) {
			var handle = child.live();
			var written = ChildNatives.write(handle, buffer, at, end - at);
			if (written < 0)
				return Err(ChildNatives.lastError());
			at += written;
			if (written == 0 && ChildNatives.wait(handle, Readiness.Stdin, -1) < 0)
				return Err(ChildNatives.lastError());
		}
		return Ok();
	}

	/** Closes the child's input, so it reads its end; closing it again does nothing. */
	public function close():Void {
		if (closed)
			return;
		closed = true;
		if (!child.isClosed())
			ChildNatives.closeStdin(child.live());
	}

	/** Whether `close` has been called. */
	public function isClosed():Bool
		return closed;
}
