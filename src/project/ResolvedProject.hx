package project;

class ResolvedProject {
	public final root:String;
	public final manifestPath:String;
	public final manifest:ProjectManifest;
	public final rootPackage:ResolvedPackage;
	public final packages:ResolvedPackageGraph;

	public function new(root:String, manifestPath:String, manifest:ProjectManifest, rootPackage:ResolvedPackage, packages:ResolvedPackageGraph) {
		this.root = root;
		this.manifestPath = manifestPath;
		this.manifest = manifest;
		this.rootPackage = rootPackage;
		this.packages = packages;
	}
}
