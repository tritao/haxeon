package tools;

import haxe.io.Path;
import sys.FileSystem;

/**
 * The Haxe source files named on a command line. A directory stands for the `.hx` files under it: HashLink's native file read
 * crashes the process on a directory instead of failing, so commands that read user-given paths go through here first.
 */
class SourceFiles {
	/** Each path as a file, or the `.hx` files under it in name order when it is a directory. */
	public static function expand(paths:Array<String>):Array<String> {
		var files:Array<String> = [];
		for (path in paths) {
			if (!FileSystem.exists(path))
				throw 'Source file not found: $path';
			if (FileSystem.isDirectory(path))
				collect(path, files);
			else
				files.push(path);
		}
		return files;
	}

	/** Throws unless `path` is a readable file; for options that name one file, such as a manifest. */
	public static function requireFile(path:String):String {
		if (!FileSystem.exists(path))
			throw 'File not found: $path';
		if (FileSystem.isDirectory(path))
			throw 'Expected a file but found a directory: $path';
		return path;
	}

	static function collect(directory:String, into:Array<String>):Void {
		var names = FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			var path = Path.join([directory, name]);
			if (FileSystem.isDirectory(path))
				collect(path, into);
			else if (StringTools.endsWith(name, ".hx"))
				into.push(path);
		}
	}
}
