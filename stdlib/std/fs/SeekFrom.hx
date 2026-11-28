package std.fs;

/** Where `FileHandle.seek` counts from. */
enum SeekFrom {
	/** The file's start. */
	Start;

	/** The current position. */
	Current;

	/** The file's end. */
	End;
}
