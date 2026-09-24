package project;

import project.FfiManifest.ResolvedFfiImport;

/** Paths in a resolved package have already been canonicalized. */
class ResolvedPackage {
	public final id:PackageId;
	public final name:String;
	public final root:String;
	public final manifest:PackageManifest;
	public final source:PackageSource;
	public final sourceRoots:Array<String>;
	public final sources:Array<String>;
	public final dependencies:Array<String>;
	public final nativeSources:Array<String>;
	public final includeDirs:Array<String>;
	public final nativeCMakeInputs:Array<String>;
	public final ffiInterfaces:Array<String>;
	public final ffiProjections:Array<String>;
	public final ffiImports:Array<ResolvedFfiImport>;

	public function new(name:String, root:String, manifest:PackageManifest, sourceRoots:Array<String>, sources:Array<String>, dependencies:Array<String>,
			nativeSources:Array<String>, includeDirs:Array<String>, nativeCMakeInputs:Array<String>, ffiInterfaces:Array<String>,
			ffiProjections:Array<String>, ?ffiImports:Array<ResolvedFfiImport>, ?source:PackageSource) {
		this.id = manifest.packageId;
		this.name = name;
		this.root = root;
		this.manifest = manifest;
		this.source = source == null ? PackageSource.Path(root) : source;
		this.sourceRoots = sourceRoots.copy();
		this.sources = sources.copy();
		this.dependencies = dependencies.copy();
		this.nativeSources = nativeSources.copy();
		this.includeDirs = includeDirs.copy();
		this.nativeCMakeInputs = nativeCMakeInputs.copy();
		this.ffiInterfaces = ffiInterfaces.copy();
		this.ffiProjections = ffiProjections.copy();
		this.ffiImports = ffiImports == null ? [] : ffiImports.copy();
	}
}
