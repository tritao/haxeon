package project;

/** Compatibility facade for project-oriented callers. */
class ProjectDiscovery {
	public static inline var MANIFEST_NAME = PackageResolver.MANIFEST_NAME;

	public static function discover(manifestPath:String):ResolvedProject
		return new PackageResolver(new PathSourceAcquirer()).resolve(manifestPath);
}
