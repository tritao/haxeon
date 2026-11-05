package build;

import haxe.io.Path;
import sys.io.File;

/** Resolve the checkout-built VM using the same path table as the shell entry points. */
class HashLinkPath {
	public static function directory(home:String):String {
		var preset = Sys.systemName() == "Windows" ? "windows-msvc" : "release";
		for (line in File.getContent(Path.join([home, "cmake", "hashlink-output-paths.txt"])).split("\n")) {
			var fields = line.split("=");
			if (fields.length == 2 && fields[0] == preset && fields[1] != "")
				return Path.join([home, StringTools.trim(fields[1])]);
		}
		throw 'Missing HashLink output path for $preset';
	}

	public static function executable(home:String, name:String = "hl"):String
		return Path.join([directory(home), name + (Sys.systemName() == "Windows" ? ".exe" : "")]);
}
