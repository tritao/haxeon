package project;

/** Selects the acquisition implementation appropriate for each package source. */
class ProjectSourceAcquirer implements SourceAcquirer {
	final path:PathSourceAcquirer;
	final git:GitSourceAcquirer;

	public function new(gitRoot:String) {
		path = new PathSourceAcquirer();
		git = new GitSourceAcquirer(gitRoot);
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Path(_) | PackageSource.Workspace(_): path.acquire(source, ownerRoot, packageId);
			case PackageSource.Git(_, _): git.acquire(source, ownerRoot, packageId);
			case _: throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} has no configured acquirer';
		};
}
