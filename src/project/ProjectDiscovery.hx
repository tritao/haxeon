package project;

import build.Target;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** How a project's package graph is resolved for a command, a build or the editor. */
class ProjectDiscovery {
	public static inline var MANIFEST_NAME = PackageResolver.MANIFEST_NAME;

	/** Resolves path and workspace dependencies only, which are already on disk. */
	public static function discover(manifestPath:String):ResolvedProject
		return new PackageResolver(new PathSourceAcquirer()).resolve(manifestPath);

	/**
	 * Resolves as every `haxeon` command does: through the source cache, and with `haxeon.lock` beside the manifest when there
	 * is one, which the graph must then match. `offline` is for the editor: a Git dependency comes only from a checkout the
	 * cache already holds, at the commit the lockfile names, and one that is missing is an error to fix with `haxeon install`
	 * rather than a fetch.
	 */
	public static function resolve(manifestPath:String, ?target:Target, offline:Bool = false):ResolvedProject {
		var lockPath = lockfilePath(manifestPath),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null;
		return new PackageResolver(new ProjectSourceAcquirer(SourceCache.root(), null, null,
			offline)).resolve(manifestPath,
			lockfile, lockfile != null, target);
	}

	public static function lockfilePath(manifestPath:String):String
		return Path.join([Path.directory(manifestPath), "haxeon.lock"]);
}
