package std.fs;

/** How `FileHandle.open` opens a file. */
enum OpenMode {
	/** To read a file that is there. */
	Read;

	/** To write a file from its start: created when missing, emptied when there. */
	Write;

	/** To add to a file's end: created when missing; every write goes to the end. */
	Append;

	/** To read and write a file that is there, from its start, keeping what it holds. */
	ReadWrite;

	/** To write a new file: `AlreadyExists` when anything is there, which is left as it was. */
	CreateNew;
}
