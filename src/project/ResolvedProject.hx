package project;

class ResolvedProject {
	public final root:String;
	public final manifestPath:String;
	public final manifest:PackageManifest;
	public final rootPackage:ResolvedPackage;
	public final packages:ResolvedPackageGraph;
	public final lockfile:PackageLockfile;

	public function new(root:String, manifestPath:String, manifest:PackageManifest, rootPackage:ResolvedPackage, packages:ResolvedPackageGraph,
		?lockfile:PackageLockfile) {
		this.root = root;
		this.manifestPath = manifestPath;
		this.manifest = manifest;
		this.rootPackage = rootPackage;
		this.packages = packages;
		this.lockfile = lockfile == null ? new PackageLockfile([]) : lockfile;
	}
}
