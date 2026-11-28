package std.fs;

import std.fs.FileError;

#if !wasm
/** The runtime's watch (native/watch/watch.h). */
internal typedef WatcherHandle = hl.Abstract<"realtime_watcher">;

@:hlNative("haxeon_runtime", "__watch_open")
internal extern function nativeOpen():Null<WatcherHandle>;

@:hlNative("haxeon_runtime", "__watch_add")
internal extern function nativeAdd(watcher:WatcherHandle, path:String, recursive:Bool):Int;

@:hlNative("haxeon_runtime", "__watch_remove")
internal extern function nativeRemove(watcher:WatcherHandle, path:String):Bool;

@:hlNative("haxeon_runtime", "__watch_exclude")
internal extern function nativeExclude(watcher:WatcherHandle, path:String):Bool;

@:hlNative("haxeon_runtime", "__watch_wait")
internal extern function nativeWait(watcher:WatcherHandle, milliseconds:Int):Int;

@:hlNative("haxeon_runtime", "__watch_change_count")
internal extern function nativeChangeCount(watcher:WatcherHandle):Int;

@:hlNative("haxeon_runtime", "__watch_change_kind")
internal extern function nativeChangeKind(watcher:WatcherHandle, index:Int):Int;

@:hlNative("haxeon_runtime", "__watch_change_path")
internal extern function nativeChangePath(watcher:WatcherHandle, index:Int):String;

@:hlNative("haxeon_runtime", "__watch_wake")
internal extern function nativeWake(watcher:WatcherHandle):Void;

@:hlNative("haxeon_runtime", "__watch_close")
internal extern function nativeClose(watcher:WatcherHandle):Void;
#end

/**
 * Directories watched for changes: `add` a directory, with everything under it when `recursive`, and `wait` reports
 * each path added, removed or modified there since the last wait, under the path the directory was added with. When
 * changes may have been lost, a wait says `Rescan`, and the caller compares what it keeps of the tree again.
 *
 * The system reports the changes: inotify on Linux, ReadDirectoryChangesW on Windows, FSEvents on macOS. Elsewhere, and
 * on Wasm, `open` is `Unsupported`. A watcher is used from one thread at a time, but `wake`, which any thread may call; an
 * app with an event loop waits on a thread of its own. `close` it when no wait is in progress; a `scoped` binding closes
 * it at the end of its scope.
 */
class Watcher implements Disposable {
	#if !wasm
	var handle:Null<WatcherHandle>;

	function new(handle:WatcherHandle)
		this.handle = handle;
	#else
	function new() {}
	#end

	/** A watcher with nothing added yet; `Unsupported` where the system offers no watching. */
	public static function open():Result<Watcher, FileError> {
		#if wasm
		return Err(Unsupported);
		#else
		var handle = nativeOpen();
		return handle == null ? Err(Unsupported) : Ok(new Watcher(handle));
		#end
	}

	/**
	 * Watches the directory `path`, and when `recursive` every directory under it, those created later included (links
	 * are not followed, and a subdirectory that cannot be read is skipped). Adding a directory again is no failure.
	 */
	public function add(path:Path, recursive:Bool = false):Result<Void, FileError> {
		#if wasm
		return Err(Unsupported);
		#else
		return switch nativeAdd(live(), path.toString(), recursive) {
			case 0: Ok();
			case 1: Err(NotFound);
			case 2: Err(NotADirectory);
			case 3: Err(PermissionDenied);
			case 4: Err(Io(0, "the system's limit on watched directories is reached"));
			case code: Err(Io(code, "the directory could not be watched"));
		};
		#end
	}

	/** Stops watching the directory `path`, added before, and everything watched under it; `NotFound` when it was not. */
	public function remove(path:Path):Result<Void, FileError> {
		#if wasm
		return Err(Unsupported);
		#else
		return nativeRemove(live(), path.toString()) ? Ok() : Err(NotFound);
		#end
	}

	/** Leaves `path` and everything under it out of the recursive registrations, those made before and after. */
	public function exclude(path:Path):Void {
		#if !wasm
		if (!nativeExclude(live(), path.toString()))
			throw new haxe.Exception('std.fs.Watcher could not exclude "$path"');
		#end
	}

	/**
	 * Waits up to `timeoutSeconds` (negative: without limit) for a change, and answers every change since the last
	 * wait, in the order they happened; nothing when the time ran out or `wake` was called.
	 */
	public function wait(timeoutSeconds:Float):Array<WatchEvent> {
		#if wasm
		return [];
		#else
		var held = live();
		var milliseconds = timeoutSeconds < 0 ? -1 : timeoutSeconds > 2147483
			? 2147483647 : Std.int(timeoutSeconds * 1000);
		var result = nativeWait(held, milliseconds);
		var events:Array<WatchEvent> = [];
		for (index in 0...nativeChangeCount(held)) {
			var kind:Null<ChangeKind> = switch nativeChangeKind(held, index) {
				case 1: Added;
				case 2: Removed;
				case 3: Modified;
				case _: null;
			};
			if (kind != null)
				events.push(Changed(Path.of(nativeChangePath(held, index)), kind));
		}
		if (result == 2)
			events.push(Rescan);
		return events;
		#end
	}

	/** From any thread: makes a wait in progress, or the next one, return now. */
	public function wake():Void {
		#if !wasm
		var held = handle;
		if (held != null)
			nativeWake(held);
		#end
	}

	/** Whether `close` has been called. */
	public function isClosed():Bool {
		#if wasm
		return false;
		#else
		return handle == null;
		#end
	}

	/** Stops watching; the watcher cannot be used afterwards. Closing it again does nothing. */
	public function close():Void {
		#if !wasm
		var held = handle;
		handle = null;
		if (held != null)
			nativeClose(held);
		#end
	}

	/** Closes the watcher, as `close` does. */
	public function dispose():Void
		close();

	#if !wasm
	function live():WatcherHandle {
		var held = handle;
		if (held == null)
			throw new haxe.Exception("std.fs.Watcher is closed");
		return held;
	}
	#end
}
