package haxeon.platform;

import nativekit.ffi.NativeKitTypes.FileChangeType;
import nativekit.ffi.NativeKitTypes.FileItemKind;

/** One change a file watch reported. Paths are absolute but not canonical: compare them with FileWatch.pathKey. */
class FileWatchChange {
	public final change:FileChangeType;
	public final item:FileItemKind;
	public final path:String;
	/** The path before a move, or null. */
	public final oldPath:Null<String>;
	/** The backend could not tell exactly what changed at `path`, so it needs a rescan. */
	public final rescan:Bool;

	public function new(change:FileChangeType, item:FileItemKind, path:String, oldPath:Null<String>, rescan:Bool) {
		this.change = change;
		this.item = item;
		this.path = path;
		this.oldPath = oldPath;
		this.rescan = rescan;
	}
}
