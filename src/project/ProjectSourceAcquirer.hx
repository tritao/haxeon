package project;

/** Selects the acquisition implementation appropriate for each package source. */
class ProjectSourceAcquirer implements SourceAcquirer {
	final path:PathSourceAcquirer;
	final git:GitSourceAcquirer;
	final haxelib:HaxelibSourceAcquirer;

	public function new(gitRoot:String, ?haxelibRoot:String) {
		path = new PathSourceAcquirer();
		git = new GitSourceAcquirer(gitRoot);
		haxelib = new HaxelibSourceAcquirer(haxelibRoot == null ? SourceCache.haxelibRoot() : haxelibRoot);
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Path(_) | PackageSource.Workspace(_): path.acquire(source, ownerRoot, packageId);
			case PackageSource.Git(_, _): git.acquire(source, ownerRoot, packageId);
			case PackageSource.Haxelib(_, _): haxelib.acquire(source, ownerRoot, packageId);
			case _: throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} has no configured acquirer';
		};
}
