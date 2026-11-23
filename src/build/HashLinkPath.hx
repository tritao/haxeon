package build;

import compiler.core.InternalError;
import haxe.io.Path;
import sys.io.File;

/** The VM's directory, the bin of Haxeon's SDK: a checkout's from the same path table as the shell entry points, or a release's. */
class HashLinkPath {
	public static function directory(home:String):String {
		// A release is its SDK, whose bin is the VM's directory; a checkout's is the bin of out/sdk, which the table gives.
		if (HaxeonRelease.isRelease(home))
			return Path.join([home, HaxeonRelease.BIN]);
		var preset = Sys.systemName() == "Windows" ? "windows-msvc" : "release", published = tablePath(home, preset);
		if (published == null)
			throw new InternalError('Missing HashLink output path for $preset');
		return published;
	}

	/**
	 * Where the build of CMake preset `preset` publishes the VM: the table's path for a preset it names (the checkout's SDK), the
	 * bin of the SDK the build stages in its own directory for any other (CMakeLists.txt, HAXEON_SDK_DIR).
	 */
	public static function forPreset(home:String, preset:String):String {
		var published = tablePath(home, preset);
		return published != null ? published : Path.join([home, "out", "cmake", preset, "sdk", "bin"]);
	}

	static function tablePath(home:String, preset:String):Null<String> {
		for (line in File.getContent(Path.join([home, "cmake", "hashlink-output-paths.txt"])).split("\n")) {
			var fields = line.split("=");
			if (fields.length == 2 && fields[0] == preset && fields[1] != "")
				return Path.join([home, StringTools.trim(fields[1])]);
		}
		return null;
	}

	public static function executable(home:String, name:String = "hl"):String
		return Path.join([directory(home), name + (Sys.systemName() == "Windows" ? ".exe" : "")]);
}
