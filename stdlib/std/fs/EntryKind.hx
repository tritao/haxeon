package std.fs;

/** What an entry of a directory is. A symbolic link is itself, not what it points to. */
enum EntryKind {
	/** A regular file. */
	File;

	/** A directory. */
	Directory;

	/** A symbolic link (on Windows, a junction too). */
	SymbolicLink;

	/** Anything else: a device, a pipe, a socket. */
	Other;
}
