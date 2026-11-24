package build;

/**
 * Where a build's progress goes: the executor's action lines and the compiler worker's messages. Standard output by
 * default; while `capture` is in effect the lines are kept instead, so a quiet run (`haxeon run --quiet`, a script) prints
 * them only if the build fails. Either way each line also reaches `OutputCapture`'s listener, which is how `haxeon run
 * --watch` streams a rebuild's output into its events file.
 */
class BuildOutput {
	static var captured:Null<Array<String>> = null;
	#if (target.threaded && !eval)
	/** Actions run on several threads, and each one's output arrives as it finishes. */
	static final keeping = new sys.thread.Mutex();
	#end

	public static function line(text:String):Void {
		if (captured != null)
			keep(text);
		else
			Sys.println(text);
		build.execution.OutputCapture.record(text + "\n");
	}

	/** Whether lines are kept rather than printed: an external process's output then comes here too. */
	public static function capturing():Bool
		return captured != null;

	/** A line for standard error: a diagnostic or a failure. */
	public static function error(text:String):Void {
		if (captured != null)
			keep(text);
		else {
			// What standard output holds goes first, so the two read in order when they share a pipe.
			Sys.stdout().flush();
			Sys.stderr().writeString(text + "\n");
		}
		// Listeners (a watch's events file) get the text without the terminal's colours.
		build.execution.OutputCapture.record(~/\x1b\[[0-9;]*m/g.replace(text, "") + "\n");
	}

	static function keep(text:String):Void {
		#if (target.threaded && !eval)
		keeping.acquire();
		#end
		var lines = captured;
		if (lines != null)
			lines.push(text);
		#if (target.threaded && !eval)
		keeping.release();
		#end
	}

	/** Keeps the lines from now on instead of printing them. */
	public static function capture():Void
		captured = [];

	/** Stops keeping lines and returns those kept. */
	public static function release():Array<String> {
		var lines = captured == null ? [] : captured;
		captured = null;
		return lines;
	}
}
