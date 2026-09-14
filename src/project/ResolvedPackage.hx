package project;

/** Paths in a resolved package have already been canonicalized. */
class ResolvedPackage {
	public final name:String;
	public final root:String;
	public final manifest:ProjectManifest;
	public final sourceRoots:Array<String>;
	public final sources:Array<String>;
	public final dependencies:Array<String>;
	public final nativeSources:Array<String>;
	public final includeDirs:Array<String>;

	public function new(name:String, root:String, manifest:ProjectManifest, sourceRoots:Array<String>, sources:Array<String>, dependencies:Array<String>,
			nativeSources:Array<String>, includeDirs:Array<String>) {
		this.name = name;
		this.root = root;
		this.manifest = manifest;
		this.sourceRoots = sourceRoots.copy();
		this.sources = sources.copy();
		this.dependencies = dependencies.copy();
		this.nativeSources = nativeSources.copy();
		this.includeDirs = includeDirs.copy();
	}
}
