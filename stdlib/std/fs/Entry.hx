package std.fs;

/** One entry of a directory, as `Files.list` gives it. */
class Entry {
	/** The entry's name in its directory, without the directory's path. */
	public final name:String;

	/** What the entry is; a symbolic link is `SymbolicLink`, whatever it points to. */
	public final kind:EntryKind;

	/** The entry `name`, of `kind`. */
	public function new(name:String, kind:EntryKind) {
		this.name = name;
		this.kind = kind;
	}
}
