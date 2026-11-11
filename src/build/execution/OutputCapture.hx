package build.execution;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Hands each line a build prints to a listener while one is set. `haxeon run --watch` streams a rebuild's output into
 * its events file this way (`WatchEvents`), so the watched app can show the compiler's errors and not only the
 * watcher's console. Records compiler worker messages, executor lines and child process output (ProcessRunner); the
 * console output itself is unchanged. Lines are delivered one at a time, in order, from whichever thread printed them.
 */
class OutputCapture {
	/** A line longer than this is delivered in pieces. */
	public static inline final MAX_LINE = 16 * 1024;

	static var listener:Null<String->Void> = null;
	static var pending:BytesBuffer = new BytesBuffer();

	#if (target.threaded && !eval)
	static final mutex = new sys.thread.Mutex();
	#end

	/** Sends every line printed from now on to `lines`, until `end`. */
	public static function begin(lines:String->Void):Void {
		lock();
		listener = lines;
		pending = new BytesBuffer();
		unlock();
	}

	/** Delivers a final unterminated line, then stops. */
	public static function end():Void {
		lock();
		var target = listener;
		if (target != null && pending.length > 0)
			deliver(target, pending.getBytes());
		listener = null;
		pending = new BytesBuffer();
		unlock();
	}

	/** Prints a line and records it. */
	public static function println(text:String):Void {
		Sys.println(text);
		record(text + "\n");
	}

	public static function record(text:String):Void {
		var bytes = Bytes.ofString(text);
		recordBytes(bytes, 0, bytes.length);
	}

	/** Records output a child process printed. Bytes are split into lines here, so a UTF-8 sequence is never cut. */
	public static function recordBytes(bytes:Bytes, position:Int, length:Int):Void {
		lock();
		var target = listener;
		if (target != null) {
			var start = position, index = position, stop = position + length;
			while (index < stop) {
				if (bytes.get(index) == "\n".code) {
					pending.addBytes(bytes, start, index - start);
					deliver(target, pending.getBytes());
					pending = new BytesBuffer();
					start = index + 1;
				}
				index++;
			}
			pending.addBytes(bytes, start, stop - start);
			if (pending.length > MAX_LINE) {
				deliver(target, pending.getBytes());
				pending = new BytesBuffer();
			}
		}
		unlock();
	}

	static function deliver(target:String->Void, line:Bytes):Void {
		var text = line.toString();
		if (StringTools.endsWith(text, "\r"))
			text = text.substr(0, text.length - 1);
		try
			target(text)
		catch (_:Dynamic) {}
	}

	static inline function lock():Void {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
	}

	static inline function unlock():Void {
		#if (target.threaded && !eval)
		mutex.release();
		#end
	}
}
