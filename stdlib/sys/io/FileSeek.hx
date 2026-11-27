package sys.io;

/** Where a `seek` position counts from, as in Haxe. */
enum FileSeek {
	/** From the start of the file. */
	SeekBegin;

	/** From the current position. */
	SeekCur;

	/** From the end of the file. */
	SeekEnd;
}
