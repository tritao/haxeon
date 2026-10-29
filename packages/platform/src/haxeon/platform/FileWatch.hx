package haxeon.platform;

import haxe.io.Bytes;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;

/**
	A NativeKit file watch: directories registered recursively or not, subtrees left out, and typed events.

	A recursive registration returns once its directory is watched; the directories under it may be registered
	afterwards, and `ready` is false until they all are. A caller that relies on events for correctness treats the
	watch as complete only while `ready` holds, and rescans (or polls) otherwise.

	Registrations survive what invalidates them natively: after an overflow, or a removal or move at or above one,
	the watch registers them again (not ready until that completes) and reports `Lost` for one that is gone.
**/
class FileWatch {
	static inline final CHANGE_HEADER_BYTES = 28;

	final owned:OwnedFileWatch;
	final handle:Int;
	final listener:FileWatchEvent->Void;
	final subscription:EventSubscription;
	/** Registrations by path key. */
	final registrations:Map<String, FileWatchRegistration> = [];
	/** Registrations still waiting for READY, by path key. */
	final pending:Map<String, Bool> = [];
	final excluded:Array<String> = [];
	var disposed:Bool = false;

	public var ready(get, never):Bool;

	/** Throws NativeKitError when the platform cannot watch files. */
	public static function create(events:EventPump, listener:FileWatchEvent->Void):FileWatch {
		if (listener == null)
			throw BindingError.invalidArgument("FileWatch.create", "File watch listeners cannot be null");
		var options = new FileWatchOptions();
		options.set_struct_size(FileWatchOptions.size());
		return new FileWatch(NativeKit.nk_file_watch_create_checked(options), events, listener);
	}

	function new(owned:OwnedFileWatch, events:EventPump, listener:FileWatchEvent->Void) {
		this.owned = owned;
		this.listener = listener;
		handle = owned.borrow().rawValue();
		subscription = events.listen(onEvent);
	}

	function get_ready():Bool
		return !disposed && !pending.keys().hasNext();

	/** Watches `path`, and everything under it when `recursive`; returns false when it already was. Throws
		NativeKitError when it cannot be watched. */
	public function add(path:String, recursive:Bool):Bool {
		ensureLive();
		var key = pathKey(path), registration = registrations.get(key);
		if (registration != null && (registration.recursive || !recursive))
			return false;
		register(path, recursive);
		registrations.set(key, new FileWatchRegistration(path, recursive));
		return true;
	}

	/** Stops watching `path` and everything registered under it. */
	public function remove(path:String):Void {
		ensureLive();
		var key = pathKey(path);
		if (!registrations.exists(key))
			return;
		var wasReady = ready;
		NativeKit.nk_file_watch_remove_directory_checked(owned.borrow(), path);
		for (other in [for (other in registrations.keys()) other])
			if (contains(key, other)) {
				registrations.remove(other);
				pending.remove(other);
			}
		if (!wasReady && ready)
			listener(Ready);
	}

	/** Leaves `path` and everything under it out of recursive registrations, including directories created there later. */
	public function exclude(path:String):Void {
		ensureLive();
		for (existing in excluded)
			if (contains(existing, path))
				return;
		NativeKit.nk_file_watch_exclude_directory_checked(owned.borrow(), path);
		excluded.push(path);
	}

	/** The registered directories. */
	public function directories():Array<String>
		return [for (registration in registrations) registration.path];

	/** The excluded subtrees. */
	public function exclusions():Array<String>
		return excluded.copy();

	public function isDisposed():Bool
		return disposed;

	/** Stops the backend and its events; safe to call more than once. */
	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		subscription.dispose();
		registrations.clear();
		pending.clear();
		owned.close();
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
		return parentKey == childKey || StringTools.startsWith(childKey, StringTools.endsWith(parentKey, "/") ? parentKey : parentKey + "/");

	function register(path:String, recursive:Bool):Void {
		NativeKit.nk_file_watch_add_directory_checked(owned.borrow(), path, recursive);
		pending.set(pathKey(path), true);
	}

	function onEvent(event:PlatformEvent):Void {
		switch event {
			case Raw(kind, source, _, _, _, _, data) if (!disposed && source.rawValue() == handle):
				if (kind == EventKind.FileWatchReady) {
					var path = pathIn(data, false);
					if (path != null && pending.remove(pathKey(path)) && ready)
						listener(Ready);
				} else if (kind == EventKind.FileWatchOverflow) {
					// Registered again first, so a listener sees whether the watch is still ready.
					if (rearm(null))
						listener(Overflow);
				} else if (kind == EventKind.FileChanged) {
					var change = decode(data);
					if (change == null)
						return;
					// A registration follows its subtree; only a removal, move or rescan at or above it invalidates it.
					var invalidating = change.rescan || ((change.change == FileChangeType.Removed || change.change == FileChangeType.Moved) &&
						change.item != FileItemKind.File);
					if (!invalidating || rearm(change.change == FileChangeType.Moved && change.oldPath != null ? change.oldPath : change.path))
						listener(Changed(change));
				}
			case _:
		}
	}

	/** Registers again what an event under `scope` (everything when null) may have invalidated. Returns false when the
		watch failed and disposed itself. */
	function rearm(scope:Null<String>):Bool {
		var scopeKey = scope == null ? null : pathKey(scope);
		for (key in [for (key in registrations.keys()) key]) {
			if (disposed)
				return false;
			if (scopeKey != null && !contains(scopeKey, key))
				continue;
			var registration = registrations.get(key);
			try {
				register(registration.path, registration.recursive);
			} catch (error:NativeKitError) {
				if (error.result != Result.ErrorInvalidArgument) {
					dispose();
					listener(Failed(error));
					return false;
				}
				var wasReady = ready;
				registrations.remove(key);
				pending.remove(key);
				listener(Lost(registration.path));
				if (!wasReady && ready)
					listener(Ready);
			}
		}
		return !disposed;
	}

	static function decode(data:Bytes):Null<FileWatchChange> {
		if (data == null || data.length < CHANGE_HEADER_BYTES)
			return null;
		var header:FileChangedEvent = data;
		var path = pathIn(data, false);
		if (path == null)
			return null;
		return new FileWatchChange(header.get_change_type(), header.get_item_kind(), path, pathIn(data, true),
			(header.get_flags() & FileEventFlags.RescanRequired) != 0);
	}

	static function pathIn(data:Bytes, old:Bool):Null<String> {
		if (data == null || data.length < CHANGE_HEADER_BYTES)
			return null;
		var header:FileChangedEvent = data;
		var offset = old ? header.get_old_path_offset() : header.get_path_offset();
		var length = old ? header.get_old_path_length() : header.get_path_length();
		if (offset < CHANGE_HEADER_BYTES || length < 0 || offset + length > data.length)
			return null;
		return data.getString(offset, length);
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
