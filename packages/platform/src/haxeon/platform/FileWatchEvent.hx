package haxeon.platform;

enum FileWatchEvent {
	/** A file or directory changed. */
	Changed(change:FileWatchChange);
	/** Changes were missed: everything watched needs a rescan. */
	Overflow;
	/** Every registration is now watched (`ready` became true); changes are reported from here on. */
	Ready;
	/** A registered directory no longer exists, so it is no longer watched. */
	Lost(path:String);
	/** The watch could not register a directory again and has disposed itself; changes are no longer reported. */
	Failed(error:NativeKitError);
}
