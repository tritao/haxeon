package std.fs;

/** What `Files.metadata` reads about a path. */
class Metadata {
	/** What is at the path. */
	public final kind:EntryKind;

	/** The size in bytes, of a file; 0 for a directory. */
	public final size:haxe.Int64;

	/** The last modification, in seconds since 1970-01-01 UTC, with the fraction the system keeps. */
	public final modified:Float;

	/** Metadata of a `kind` of `size` bytes, last modified at `modified`. */
	public function new(kind:EntryKind, size:haxe.Int64, modified:Float) {
		this.kind = kind;
		this.size = size;
		this.modified = modified;
	}

	/** Whether the path is a regular file. */
	public inline function isFile():Bool
		return kind == File;

	/** Whether the path is a directory. */
	public inline function isDirectory():Bool
		return kind == Directory;
}
