package project;

class ResolvedPackageGraph {
	/** Dependency-first deterministic order. */
	public final packages:Array<ResolvedPackage>;

	final byName:Map<String, ResolvedPackage>;

	public function new(packages:Array<ResolvedPackage>) {
		this.packages = packages.copy();
		byName = new Map();
		for (resolvedPackage in this.packages) {
			if (byName.exists(resolvedPackage.name))
				throw 'Duplicate package name "${resolvedPackage.name}"';
			byName.set(resolvedPackage.name, resolvedPackage);
		}
	}

	public function get(name:String):Null<ResolvedPackage>
		return byName.get(name);

	public function names():Array<String>
		return [for (resolvedPackage in packages) resolvedPackage.name];
}
