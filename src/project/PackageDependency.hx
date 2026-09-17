package project;

/** A manifest edge: identity is named by the consumer, source selects acquisition. */
class PackageDependency {
	public final id:PackageId;
	public final source:PackageSource;

	public function new(id:PackageId, source:PackageSource) {
		this.id = id;
		this.source = source;
	}

	public function toString():String
		return '${id.name} (${PackageSourceTools.describe(source)})';
}
