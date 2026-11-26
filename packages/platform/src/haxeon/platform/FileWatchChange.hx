package haxeon.platform;

import nativekit.ffi.NativeKitTypes.FileChangeType;
import nativekit.ffi.NativeKitTypes.FileItemKind;

/** One change a file watch reported. Paths are absolute but not canonical: compare them with FileWatch.pathKey. */
class FileWatchChange {
	/** What happened. */
	public final change:FileChangeType;

	/** Whether it is a file or a directory. */
	public final item:FileItemKind;

	/** Where it happened. */
	public final path:String;
	/** The path before a move, or null. */
	public final oldPath:Null<String>;
	/** The backend could not tell exactly what changed at `path`, so it needs a rescan. */
	public final rescan:Bool;

	/** A change to `path`. */
	public function new(change:FileChangeType, item:FileItemKind, path:String, oldPath:Null<String>, rescan:Bool) {
		this.change = change;
		this.item = item;
		this.path = path;
		this.oldPath = oldPath;
		this.rescan = rescan;
	}
}
