package project;

import compiler.core.InternalError;

/** Selects the acquisition implementation appropriate for each package source. */
class ProjectSourceAcquirer implements SourceAcquirer {
	final path:PathSourceAcquirer;
	final git:GitSourceAcquirer;
	final haxelib:HaxelibSourceAcquirer;
	final registry:RegistrySourceAcquirer;

	/**
	 * `offline` acquires without the network: Git sources come only from checkouts the cache already holds (registry and Haxelib
	 * sources always come from the local cache).
	 */
	public function new(gitRoot:String, ?haxelibRoot:String, ?registryRoot:String, offline:Bool = false) {
		path = new PathSourceAcquirer();
		git = new GitSourceAcquirer(gitRoot, offline);
		haxelib = new HaxelibSourceAcquirer(haxelibRoot == null ? SourceCache.haxelibRoot() : haxelibRoot);
		registry = new RegistrySourceAcquirer(registryRoot == null ? SourceCache.registryRoot() : registryRoot);
	}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Path(_) | PackageSource.Workspace(_): path.acquire(source, ownerRoot, packageId);
			case PackageSource.Git(_, _): git.acquire(source, ownerRoot, packageId);
			case PackageSource.Haxelib(_, _): haxelib.acquire(source, ownerRoot, packageId);
			case PackageSource.Registry(_, _, _): registry.acquire(source, ownerRoot, packageId);
			case _: throw new InternalError('Package "$packageId" source ${PackageSourceTools.describe(source)} has no configured acquirer');
		};
}
