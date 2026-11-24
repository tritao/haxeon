package project;

import build.HaxeonSdk;
import build.Target;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** How a project's package graph is resolved for a command, a build or the editor. */
class ProjectDiscovery {
	/** Resolves path and workspace dependencies only, which are already on disk. */
	public static function discover(manifestPath:String):ResolvedProject
		return new PackageResolver(new PathSourceAcquirer()).resolve(manifestPath);

	/**
	 * Resolves as every `haxeon` command does: through the source cache, and with `haxeon.lock` beside the manifest when there
	 * is one, which the graph must then match. `offline` is for the editor: a Git dependency comes only from a checkout the
	 * cache already holds, at the commit the lockfile names, and one that is missing is an error to fix with `haxeon install`
	 * rather than a fetch. `program` is a root manifest made in memory, placed at `manifestPath` (`PackageResolver.resolve`).
	 */
	public static function resolve(manifestPath:String, ?target:Target, offline:Bool = false,
			?program:PackageManifest):ResolvedProject {
		var lockPath = lockfilePath(manifestPath),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null;
		return new PackageResolver(sourceAcquirer(offline)).resolve(manifestPath, lockfile, lockfile != null, target,
			program);
	}

	/** What every `haxeon` command acquires packages with: the source cache, and the SDK's registry as the `haxeon` registry. */
	public static function sourceAcquirer(offline:Bool = false):ProjectSourceAcquirer {
		var home = HaxeonSdk.current();
		return new ProjectSourceAcquirer(SourceCache.root(), null, null, offline,
			home == null ? null : HaxeonSdk.registryRoot(home));
	}

	public static function lockfilePath(manifestPath:String):String
		return Path.join([Path.directory(manifestPath), "haxeon.lock"]);
}
