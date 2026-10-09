package haxeon.filesystem.tests;

import haxeon.filesystem.FileSystemRoot;

class FileSystemSmoke {
	static function main():Void {
		var root = new FileSystemRoot(Sys.getCwd());
		if (root.stat("").get_kind() != 2)
			throw "root stat did not return a directory";

		var cursor = root.openDirectory("");
		var foundName = false;
		for (_ in 0...10) {
			var entry = cursor.next();
			if (entry == null)
				break;
			if (entry.name != null && entry.name.length > 0) {
				foundName = true;
				break;
			}
		}
		if (!foundName)
			throw "directory iteration did not return a supported UTF-8 name";
		cursor.close();
		root.close();
	}
}
