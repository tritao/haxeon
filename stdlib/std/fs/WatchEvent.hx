package std.fs;

/** What a `Watcher`'s wait observed. */
enum WatchEvent {
	/** The entry at `path` was `kind`, under the path its directory was added with. */
	Changed(path:Path, kind:ChangeKind);

	/**
	 * Changes were lost (a kernel queue or buffer overflowed, or a new directory could not be watched): compare what is
	 * kept of the tree with it again. The changes reported beside it did happen.
	 */
	Rescan;
}
