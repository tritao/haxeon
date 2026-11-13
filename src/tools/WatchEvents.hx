package tools;

import haxe.Json;
import sys.io.File;

/**
	What `haxeon run --watch` does with each edit, one JSON object per line in `<output>.watch-events.jsonl`, for the
	watched app and for tools. The console says the same things, but nothing reads the console. The watcher passes the
	path to the app it launches in `HAXEON_WATCH_EVENTS`; a live host (`LiveHost`) inherits it and adds what it did with
	each patch.

	Every event has `kind` and `time` (epoch ms); the other fields are null where they do not apply:

	- `rebuild-started`: `build` (rebuilds since the watch started), `changedFiles`.
	- `output-line`: `build`, `line`, one per line the build printed (compiler errors are `file:line:column: CODE: text`).
	- `build-failed`: `build`.
	- `build-ok`: `build`, and `revision` in live mode.
	- `patch-published`: `build`, `revision`, `reloadReasons` (empty unless the edit needs a reload).
	- `patch-applied` (live host): `revision` now running.
	- `patch-rejected` (live host): `revision` refused, `message` why; the app keeps the revision it ran.
	- `reload`: `revision`, `message`; the watcher restarting the app, or the live host reloading its module.

	The file is emptied when the watch starts, and moved to `<file>.1` once it passes `MAX_BYTES`. Each write is one
	append of whole lines, so the watcher and the live host can both write it. A build's `output-line` events are
	appended in batches (`WatchEventLines`); every other event is its own append.
**/
class WatchEvents {
	public static inline final ENVIRONMENT = "HAXEON_WATCH_EVENTS";
	public static inline final MAX_BYTES = 4 * 1024 * 1024;

	public static function pathFor(output:String):String
		return output + ".watch-events.jsonl";

	/** The events file of the watch this process runs under, or null outside one. */
	public static function current():Null<String> {
		var path = Sys.getEnv(ENVIRONMENT);
		return path == null || path.length == 0 ? null : path;
	}

	/** Starts the file empty, for a new watch. */
	public static function reset(path:String):Void {
		try
			File.saveContent(path, "")
		catch (error:Dynamic)
			Sys.stderr().writeString('haxeon: could not start $path: ${Std.string(error)}\n');
	}

	public static function emit(path:Null<String>, kind:String, ?build:Int, ?revision:Int, ?line:String, ?changedFiles:Array<String>,
			?reloadReasons:Array<String>, ?message:String):Void {
		if (path != null)
			append(path, encode(kind, build, revision, line, changedFiles, reloadReasons, message));
	}

	/** One event as its line of the file, newline included. */
	public static function encode(kind:String, ?build:Int, ?revision:Int, ?line:String, ?changedFiles:Array<String>, ?reloadReasons:Array<String>,
			?message:String):String
		return Json.stringify({
			kind: kind,
			time: Math.ffloor(Sys.time() * 1000.0),
			build: build,
			revision: revision,
			line: line,
			changedFiles: changedFiles,
			reloadReasons: reloadReasons,
			message: message
		}) + "\n";

	/** Appends whole event lines in one open, write and close. A failure is swallowed: the events file never breaks a build. */
	public static function append(path:String, text:String):Void {
		try {
			#if haxeon
			File.appendContent(path, text);
			#else
			var output = File.append(path, false);
			output.writeString(text);
			output.close();
			#end
		} catch (_:Dynamic) {}
	}
}
