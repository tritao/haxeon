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

	When changes were lost the watch registers its directories again (picking up any created meanwhile), then reports
	`Rescan`; a registered directory that is gone, whether it was removed or could not be registered again, is reported
	`Lost` and forgotten.
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
	public function exclude(path:String):Void {
		ensureLive();
		for (existing in excluded)
			if (contains(pathKey(existing), pathKey(path)))
				return;
		_ = ask(Exclude(path, new FileWatchReply()));
		excluded.push(path);
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

	/** The watching thread: waits for changes, carries out what the app thread asked, and posts what changed to it. */
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
						reply.done.release();
					case Remove(path, reply):
						reply.result = watcher.remove(path);
						reply.done.release();
					case Exclude(path, reply):
						watcher.exclude(path);
						reply.done.release();
					case Stop:
						stopping = true;
				}
			if (!stopping && changes.length > 0)
				events.post(() -> deliver(changes));
		}
		watcher.close();
		stopped.release();
	}

	/** On the app thread: reports `changes`, forgets the registrations that went, and registers again after a loss. */
	function deliver(changes:Array<WatchEvent>):Void {
		if (disposed)
			return;
		var lost = false;
		for (change in changes)
			switch change {
				case Changed(path, kind):
					var at = path.toString();
					listener(Changed(at, kind));
					if (kind == Removed)
						lose(pathKey(at));
				case Rescan:
					lost = true;
			}
		if (lost && !disposed)
			renew();
	}

	/** Registers every directory again, picking up what was created while changes were lost, then reports `Rescan`. */
	function renew():Void {
		for (registration in [for (registration in registrations) registration]) {
			if (disposed)
				return;
			switch ask(Add(registration.path, registration.recursive, new FileWatchReply())) {
				case Ok(_):
				case Err(NotFound | NotADirectory): lose(pathKey(registration.path));
				case Err(error):
					dispose();
					listener(Failed(error));
					return;
			}
		}
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
