package build;

import compiler.core.InternalError;
import haxe.io.Path;
import sys.io.File;

/** Resolve the checkout-built VM using the same path table as the shell entry points, or a release's (`HaxeonRelease`). */
class HashLinkPath {
	public static function directory(home:String):String {
		if (HaxeonRelease.isRelease(home))
			return Path.join([home, HaxeonRelease.BIN]);
		var preset = Sys.systemName() == "Windows" ? "windows-msvc" : "release";
		for (line in File.getContent(Path.join([home, "cmake", "hashlink-output-paths.txt"])).split("\n")) {
			var fields = line.split("=");
			if (fields.length == 2 && fields[0] == preset && fields[1] != "")
				return Path.join([home, StringTools.trim(fields[1])]);
		}
		throw new InternalError('Missing HashLink output path for $preset');
	}

	public static function executable(home:String, name:String = "hl"):String
		return Path.join([directory(home), name + (Sys.systemName() == "Windows" ? ".exe" : "")]);
}
