package haxeon.platform;

import haxeon.platform.event.EventPump;
import std.fs.FileError;
import std.fs.WatchEvent;
import std.fs.Watcher;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
	Directories watched on a thread of their own, their changes delivered on the event pump's thread: `std.fs.Watcher`
	for an app with an event loop. A registration is complete when `add` returns. Paths are reported under the spelling
	a directory was added with; compare them with `pathKey`.

	When changes were lost the watching thread registers its directories again (picking up any created meanwhile), and
	the watch then reports `Rescan`; a registered directory that is gone, whether it was removed or could not be
	registered again, is reported `Lost` and forgotten. The app thread never waits for that walk.
**/
class FileWatch implements Disposable {
	final events:EventPump;
	final listener:FileWatchEvent->Void;
	final watcher:Watcher;
	/** What the app thread asks the watching thread, under `guard`. */
	final commands:Array<FileWatchCommand> = [];
	final guard = new Mutex();
	final stopped = new Lock();
	/** Registrations by path key, kept on the app thread. */
	final registrations:Map<String, FileWatchRegistration> = [];
	/** The same registrations, kept on the watching thread to renew them without asking the app thread. */
	final watched:Map<String, FileWatchRegistration> = [];
	final excluded:Array<String> = [];
	var disposed:Bool = false;

	/** A watch delivering its events to `listener` through `events`; `Unsupported` where the system cannot watch. */
	public static function create(events:EventPump, listener:FileWatchEvent->Void):Result<FileWatch, FileError> {
		if (events == null || listener == null)
			throw BindingError.invalidArgument("FileWatch.create", "A file watch needs an event pump and a listener");
		var watch = new FileWatch(events, listener, try Watcher.open());
		Thread.create(watch.watch);
		return Ok(watch);
	}

	function new(events:EventPump, listener:FileWatchEvent->Void, watcher:Watcher) {
		this.events = events;
		this.listener = listener;
		this.watcher = watcher;
	}

	/**
		Watches the directory `path`, and everything under it when `recursive`, from when it returns. Adding a
		directory again is no failure; `NotFound`, `NotADirectory` or `PermissionDenied` when it cannot be watched.
	**/
	public function add(path:String, recursive:Bool):Result<Void, FileError> {
		ensureLive();
		var key = pathKey(path), registration = registrations.get(key);
		if (registration != null && (registration.recursive || !recursive))
			return Ok();
		var added = ask(Add(path, recursive, new FileWatchReply()));
		if (added.isOk())
			registrations.set(key, new FileWatchRegistration(path, recursive));
		return added;
	}

	/** Stops watching `path` and everything registered under it. */
	public function remove(path:String):Void {
		ensureLive();
		var key = pathKey(path);
		if (!registrations.exists(key))
			return;
		_ = ask(Remove(path, new FileWatchReply()));
		for (other in [for (other in registrations.keys()) other])
			if (contains(key, other))
				registrations.remove(other);
	}

	/** Leaves `path` and everything under it out of recursive registrations, including directories created there later. */
	public function exclude(path:String):Result<Void, FileError> {
		ensureLive();
		for (existing in excluded)
			if (contains(pathKey(existing), pathKey(path)))
				return Ok();
		var excluding = ask(Exclude(path, new FileWatchReply()));
		if (excluding.isOk())
			excluded.push(path);
		return excluding;
	}

	/** The registered directories. */
	public function directories():Array<String>
		return [for (registration in registrations) registration.path];

	/** The excluded subtrees. */
	public function exclusions():Array<String>
		return excluded.copy();

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	/** Stops watching, and waits for the watching thread to let go; safe to call more than once. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		send(Stop);
		stopped.wait();
		registrations.clear();
	}

	/** A path in the form events and registrations are compared in: forward slashes, no trailing one, and folded case
		where the filesystem ignores it. */
	public static function pathKey(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/"))
			normalized = normalized.substring(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	/** Whether `child` is `parent` or below it, for paths in any spelling. */
	public static function within(parent:String, child:String):Bool
		return contains(pathKey(parent), pathKey(child));

	static function contains(parentKey:String, childKey:String):Bool
		return parentKey == childKey
			|| StringTools.startsWith(childKey, StringTools.endsWith(parentKey, "/") ? parentKey : parentKey + "/");

	/** Has the watching thread carry out `command`, and answers what it did. */
	function ask(command:FileWatchCommand):Result<Void, FileError> {
		var reply = switch command {
			case Add(_, _, reply) | Remove(_, reply) | Exclude(_, reply): reply;
			case Stop: throw BindingError.invalidState("FileWatch.ask", "Stopping is not a question");
		};
		send(command);
		reply.done.wait();
		return reply.result;
	}

	function send(command:FileWatchCommand):Void {
		guard.acquire();
		commands.push(command);
		guard.release();
		watcher.wake();
	}

	/**
	 * The watching thread: waits for changes, carries out what the app thread asked, renews its registrations when
	 * changes were lost, and posts what happened to the app thread.
	 */
	function watch():Void {
		var stopping = false;
		while (!stopping) {
			var changes = watcher.wait(-1);
			guard.acquire();
			var asked = commands.splice(0, commands.length);
			guard.release();
			for (command in asked)
				switch command {
					case Add(path, recursive, reply):
						reply.result = watcher.add(path, recursive);
						if (reply.result.isOk())
							watched.set(pathKey(path), new FileWatchRegistration(path, recursive));
						reply.done.release();
					case Remove(path, reply):
						reply.result = watcher.remove(path);
						var key = pathKey(path);
						for (other in [for (other in watched.keys()) other])
							if (contains(key, other))
								watched.remove(other);
						reply.done.release();
					case Exclude(path, reply):
						reply.result = watcher.exclude(path);
						reply.done.release();
					case Stop:
						stopping = true;
				}
			if (stopping || changes.length == 0)
				continue;
			var lostChanges = Lambda.exists(changes, change -> change.match(Rescan)),
				gone:Array<String> = [],
				failure:Null<FileError> = null;
			if (lostChanges)
				failure = renew(gone);
			events.post(() -> deliver(changes, gone, failure));
		}
		watcher.close();
		stopped.release();
	}

	/**
	 * On the watching thread: registers every directory again, picking up what was created while changes were lost.
	 * Adds to `gone` the paths no longer there; answers the failure that stops the watch, or null.
	 */
	function renew(gone:Array<String>):Null<FileError> {
		for (key => registration in [for (key => registration in watched) key => registration])
			switch watcher.add(registration.path, registration.recursive) {
				case Ok(_):
				case Err(NotFound | NotADirectory):
					watched.remove(key);
					gone.push(registration.path);
				case Err(error):
					return error;
			}
		return null;
	}

	/** On the app thread: reports `changes` and what the watching thread found gone, forgetting those registrations. */
	function deliver(changes:Array<WatchEvent>, gone:Array<String>, failure:Null<FileError>):Void {
		if (disposed)
			return;
		var lostChanges = false;
		for (change in changes)
			switch change {
				case Changed(path, kind):
					var at = path.toString();
					listener(Changed(at, kind));
					if (kind == Removed)
						lose(pathKey(at));
				case Rescan:
					lostChanges = true;
			}
		for (path in gone)
			lose(pathKey(path));
		if (failure != null) {
			dispose();
			listener(Failed(failure));
		} else if (lostChanges)
			listener(Rescan);
	}

	function lose(key:String):Void {
		var registration = registrations.get(key);
		if (registration == null)
			return;
		registrations.remove(key);
		listener(Lost(registration.path));
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("FileWatch.ensureLive", "File watch has been disposed");
	}
}

private class FileWatchRegistration {
	public final path:String;
	public final recursive:Bool;

	public function new(path:String, recursive:Bool) {
		this.path = path;
		this.recursive = recursive;
	}
}

/** What the app thread asks the watching thread, which answers through `reply`. */
private enum FileWatchCommand {
	Add(path:String, recursive:Bool, reply:FileWatchReply);
	Remove(path:String, reply:FileWatchReply);
	Exclude(path:String, reply:FileWatchReply);
	Stop;
}

private class FileWatchReply {
	public var result:Result<Void, FileError> = Ok();
	public final done = new Lock();

	public function new() {}
}
