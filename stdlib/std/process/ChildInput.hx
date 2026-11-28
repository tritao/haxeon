package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import haxe.io.Bytes;
import std.process.ChildNatives;

/** What this program writes to a child's standard input, through a pipe: its `stdin`. */
class ChildInput {
	final child:Child;
	var closed:Bool = false;

	internal function new(child:Child)
		this.child = child;

	/**
	 * Writes `length` bytes of `buffer` from `offset` (by default all of it), waiting while the pipe is full, until the
	 * child has been given every one of them. `InputClosed` when it no longer reads.
	 */
	public function write(buffer:Bytes, offset:Int = 0, length:Int = -1):Result<Void, ProcessError> {
		var count = length < 0 ? buffer.length - offset : length;
		if (buffer == null || offset < 0 || count < 0 || offset > buffer.length - count)
			throw new haxe.Exception("std.process.ChildInput: the range is outside the buffer");
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

	/** Writes `text` as UTF-8. */
	public function writeText(text:String):Result<Void, ProcessError>
		return write(Bytes.ofString(text));

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
