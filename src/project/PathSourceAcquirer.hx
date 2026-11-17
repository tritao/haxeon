package project;

import compiler.core.InternalError;
import haxe.io.Path;
import sys.FileSystem;

/** Resolves package sources already present in the local filesystem. */
class PathSourceAcquirer implements SourceAcquirer {
	public function new() {}

	public function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):AcquiredSource
		return switch source {
			case PackageSource.Path(path) | PackageSource.Workspace(path):
				var root = Path.normalize(Path.isAbsolute(path) ? path : Path.join([ownerRoot, path]));
				if (!FileSystem.exists(root) || !FileSystem.isDirectory(root))
					throw new InternalError(MissingPath.describe('Package "$packageId" path source', root));
				new AcquiredSource(FileSystem.fullPath(root), source);
			case _:
				throw new InternalError('Package "$packageId" source ${PackageSourceTools.describe(source)} is not supported by the path acquirer');
		};
}
