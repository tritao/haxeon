package project;

import haxe.io.Path;

/** Locations for immutable dependency sources, intentionally separate from build outputs. */
class SourceCache {
	public static function root():String
		return build.UserCache.directory("sources", "HAXEON_SOURCE_CACHE");

	public static function gitRoot():String
		return Path.join([root(), "git"]);

	public static function registryRoot():String
		return Path.join([root(), "registry"]);

	public static function haxelibRoot():String
		return Path.join([root(), "haxelib"]);

	public static function downloadsRoot():String {
		var sourceRoot = Path.directory(root());
		return Path.join([sourceRoot, "downloads"]);
	}

	public static function registryDownloadsRoot():String
		return Path.join([registryRoot(), "downloads"]);
}
