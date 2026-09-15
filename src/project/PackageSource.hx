package project;

/** Declarative origin of package source. Resolution is intentionally separate. */
enum PackageSource {
	Path(path:String);
	Git(url:String, rev:String);
	Registry(registry:String, name:String, version:String);
	Haxelib(name:String, version:String);
}
