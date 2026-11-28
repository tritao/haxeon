package haxeon.platform;

import std.fs.ChangeKind;
import std.fs.FileError;

/** What a file watch reports, on the event pump's thread. */
enum FileWatchEvent {
	/** The entry at `path` was `kind`; compare paths with `FileWatch.pathKey`. */
	Changed(path:String, kind:ChangeKind);

	/**
	 * Changes were lost. The registrations were renewed, so what is reported from here on is complete again; what
	 * happened before needs comparing with the tree.
	 */
	Rescan;

	/** A registered directory no longer exists, so it is no longer watched. */
	Lost(path:String);

	/** The watch could not register a directory again and has disposed itself; changes are no longer reported. */
	Failed(error:FileError);
}
