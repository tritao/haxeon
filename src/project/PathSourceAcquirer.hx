package project;

import haxe.io.Path;
import sys.FileSystem;

/** Resolves package sources already present in the local filesystem. */
class PathSourceAcquirer implements SourceAcquirer {
	public function new() {}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):String
		return switch source {
			case PackageSource.Path(path):
				var root = Path.normalize(Path.isAbsolute(path) ? path : Path.join([ownerRoot, path]));
				if (!FileSystem.exists(root) || !FileSystem.isDirectory(root))
					throw 'Package "$packageId" path source does not exist: $root';
				FileSystem.fullPath(root);
			case _:
				throw 'Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the path acquirer';
		};
}
