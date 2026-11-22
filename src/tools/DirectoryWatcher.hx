package tools;

/**
	Change notifications for directories, used by the watch loop to start compiling right after a save instead of
	waiting for the next poll. A notification says only that something under a watched directory may have changed (or
	that notifications were lost); the caller compares its own snapshot, so the watcher never decides what an edit was.
	Unavailable (create returns null) where the platform has no backend or a directory cannot be watched, and the
	caller polls instead. The natives take the path as a String and the watch as an opaque handle, so the CLI binds them
	the same way whether stock Haxe or Haxeon built it.
**/
class DirectoryWatcher {
	#if hl
	@:hlNative("haxeon_runtime", "__dir_watch_open")
	static function nativeOpen():Null<WatchHandle>
		return null;

	@:hlNative("haxeon_runtime", "__dir_watch_add")
	static function nativeAdd(handle:WatchHandle, path:String, recursive:Bool):Bool
		return false;

	@:hlNative("haxeon_runtime", "__dir_watch_wait")
	static function nativeWait(handle:WatchHandle, milliseconds:Int):Int
		return 2;

	@:hlNative("haxeon_runtime", "__dir_watch_close")
	static function nativeClose(handle:WatchHandle):Void {}

	var handle:Null<WatchHandle>;
	#end

	function new() {}

	/** Watches each directory (a recursive one with everything under it), or returns null when they cannot all be watched. */
	public static function create(directories:Array<{path:String, recursive:Bool}>):Null<DirectoryWatcher> {
		#if hl
		var handle = try nativeOpen() catch (error:Dynamic) null;
		if (handle == null)
			return null;
		for (directory in directories)
			if (!nativeAdd(handle, directory.path, directory.recursive)) {
				nativeClose(handle);
				return null;
			}
		var watcher = new DirectoryWatcher();
		watcher.handle = handle;
		return watcher;
		#else
		return null;
		#end
	}

	/** Waits up to `seconds` for a change. True when something changed or changes may have been lost; false on timeout. */
	public function wait(seconds:Float):Bool {
		#if hl
		return handle == null ? true : nativeWait(handle, Std.int(seconds * 1000)) != 0;
		#else
		return true;
		#end
	}

	public function close():Void {
		#if hl
		if (handle != null)
			nativeClose(handle);
		handle = null;
		#end
	}
}

#if hl
/** The runtime's watch (native/runtime/dir_watch.c), opaque here. */
private typedef WatchHandle = hl.Abstract<"realtime_dir_watch">;
#end
