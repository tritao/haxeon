package project;

import haxe.io.Path;

/** Locations for immutable dependency sources, intentionally separate from build outputs. */
class SourceCache {
	public static function root():String {
		var cacheOverride = Sys.getEnv("HAXEON_SOURCE_CACHE");
		if (cacheOverride != null && cacheOverride.length > 0)
			return Path.normalize(cacheOverride);
		var userHome = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
		if (userHome == null || userHome.length == 0)
			userHome = Sys.getCwd();
		return Path.join([userHome, ".haxeon", "cache", "sources"]);
	}

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
}
