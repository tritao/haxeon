package std.fs;

/** What happened to a path a `Watcher` reports. A rename is its old path `Removed` and its new one `Added`. */
enum ChangeKind {
	/** Something was created at the path, or moved there. */
	Added;

	/** What was at the path was deleted, or moved away. */
	Removed;

	/** What is at the path changed: its contents, or its metadata. */
	Modified;
}
