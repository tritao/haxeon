package tools;

/**
	The lines one rebuild prints, on their way to the events file as `output-line` events.

	A build can print thousands of lines. Each used to be its own open, append and close of the file, made inside
	`OutputCapture`'s lock, so every thread that printed waited on the disk. `add` now only queues the event's text under
	that lock. A writer thread appends what has gathered every `FLUSH_SECONDS` in one write, so a reader still sees the
	build's output while it runs, and `close` appends the rest before the build's result event is written. Writes go
	through `WatchEvents.append`: one that fails drops those lines and never reaches the build.

	Without threads (the interpreter) each line is appended as it comes, as before.
**/
class WatchEventLines {
	public static inline final FLUSH_SECONDS = 0.1;

	final path:Null<String>;
	final build:Int;

	#if (target.threaded && !eval)
	/** Guards `pending` and `closed`; held only for memory work, since `add` runs under the capture lock. */
	final state = new sys.thread.Mutex();

	/** Held across taking the queue and appending it, so the writer thread and `close` keep the lines in order. */
	final writing = new sys.thread.Mutex();

	var pending = new StringBuf();
	var closed = false;
	#end

	public function new(path:Null<String>, build:Int) {
		this.path = path;
		this.build = build;
		#if (target.threaded && !eval)
		if (path != null)
			sys.thread.Thread.create(function() {
				runtime.ThreadName.setCurrent("haxeon.watch.events");
				while (!flush(false))
					Sys.sleep(FLUSH_SECONDS);
			});
		#end
	}

	/** Queues one printed line. This is the `OutputCapture` listener: it must not touch the file. */
	public function add(line:String):Void {
		if (path == null)
			return;
		var text = WatchEvents.encode("output-line", build, null, line);
		#if (target.threaded && !eval)
		state.acquire();
		if (!closed)
			pending.add(text);
		state.release();
		#else
		WatchEvents.append(path, text);
		#end
	}

	/** Appends what is still queued and stops the writer. Call after `OutputCapture.end`, before the build's result event. */
	public function close():Void {
		#if (target.threaded && !eval)
		if (path != null)
			flush(true);
		#end
	}

	#if (target.threaded && !eval)
	/** Appends the queued lines in one write. True once the batch is closed. */
	function flush(last:Bool):Bool {
		writing.acquire();
		state.acquire();
		if (last)
			closed = true;
		var text = pending.toString(), done = closed;
		pending = new StringBuf();
		state.release();
		if (text.length > 0)
			WatchEvents.append(path, text);
		writing.release();
		return done;
	}
	#end
}
