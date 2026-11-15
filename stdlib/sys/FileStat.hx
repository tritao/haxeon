package sys;

/** What `FileSystem.stat` reports about a file, as in Haxe. */
typedef FileStat = {
	/** The owner's group id. */
	var gid:Int;

	/** The owner's user id. */
	var uid:Int;

	/** The last access, when the file system records it. */
	var atime:Date;

	/** The last change of the content. */
	var mtime:Date;

	/** The last change of the content or the metadata. */
	var ctime:Date;

	/** The size in bytes. */
	var size:Int;

	var dev:Int;
	var ino:Int;
	var nlink:Int;
	var rdev:Int;

	/** The permission bits and kind of file. */
	var mode:Int;
}
