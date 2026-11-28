package std.bytes;

/** How a String is stored as bytes. */
enum Encoding {
	/** UTF-8. */
	Utf8;

	/** UTF-16 code units, little-endian: what Windows and many native libraries take. */
	Utf16;
}
