package tools;

/**
	Change notifications for directories, used by the watch loop to start compiling right after a save instead of
	waiting for the next poll. A notification says only that something under a watched directory may have changed (or
	that notifications were lost); the caller compares its own snapshot, so the watcher never decides what an edit was.
	Unavailable (create returns null) where the platform has no backend or a directory cannot be watched, and the
	caller polls instead.
**/
class DirectoryWatcher {
	#if (hl && !haxeon)
	@:hlNative("haxeon_runtime", "__dir_watch_open")
	static function nativeOpen():hl.Bytes
		return null;

	@:hlNative("haxeon_runtime", "__dir_watch_add")
	static function nativeAdd(handle:hl.Bytes, path:hl.Bytes, recursive:Bool):Bool
		return false;

	@:hlNative("haxeon_runtime", "__dir_watch_wait")
	static function nativeWait(handle:hl.Bytes, milliseconds:Int):Int
		return 2;

	@:hlNative("haxeon_runtime", "__dir_watch_close")
	static function nativeClose(handle:hl.Bytes):Void {}

	var handle:Null<hl.Bytes>;
	#end

	function new() {}

	/** Watches each directory (a recursive one with everything under it), or returns null when they cannot all be watched. */
	public static function create(directories:Array<{path:String, recursive:Bool}>):Null<DirectoryWatcher> {
		#if (hl && !haxeon)
		var handle = try nativeOpen() catch (error:Dynamic) null;
		if (handle == null)
			return null;
		for (directory in directories)
			if (!nativeAdd(handle, @:privateAccess directory.path.toUtf8(), directory.recursive)) {
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
		#if (hl && !haxeon)
		return handle == null ? true : nativeWait(handle, Std.int(seconds * 1000)) != 0;
		#else
		return true;
		#end
	}

	public function close():Void {
		#if (hl && !haxeon)
		if (handle != null)
			nativeClose(handle);
		handle = null;
		#end
	}
}
