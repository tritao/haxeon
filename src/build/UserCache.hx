package build;

import build.execution.ProcessRunner;
import haxe.io.Path;

/** The user's Haxeon cache, `~/.haxeon/cache` (under `USERPROFILE` on Windows): what every project and SDK of the user shares. */
class UserCache {
	/**
	 * The cache's directory `name`, or the directory the environment variable `variable` names when it is set. Without a user home it is under
	 * the working directory.
	 */
	public static function directory(name:String, ?variable:String):String {
		var configured = variable == null ? null : ProcessRunner.environmentValue(variable);
		if (configured != null && configured.length > 0)
			return Path.normalize(configured);
		var home = ProcessRunner.environmentValue(Sys.systemName() == "Windows" ? "USERPROFILE" : "HOME");
		if (home == null || home.length == 0)
			home = Sys.getCwd();
		return Path.join([home, ".haxeon", "cache", name]);
	}
}
