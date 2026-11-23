package project;

/** A manifest edge: identity is named by the consumer, source selects acquisition. */
class PackageDependency {
	public final id:PackageId;
	public final source:PackageSource;

	public final platforms:Array<String>;

	public function new(id:PackageId, source:PackageSource, ?platforms:Array<String>) {
		this.id = id;
		this.source = source;
		this.platforms = platforms == null ? [] : platforms;
	}

	public function toString():String
		return '${id.name} (${PackageSourceTools.describe(source)})';
}
