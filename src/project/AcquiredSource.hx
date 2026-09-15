package project;

/** Result of acquisition, including the immutable identity used by a lockfile. */
class AcquiredSource {
	public final root:String;
	public final source:PackageSource;
	public final resolvedRevision:Null<String>;
	public final checksum:Null<String>;
	public final compatibility:Null<PackageCompatibility>;

	public function new(root:String, source:PackageSource, ?resolvedRevision:String, ?checksum:String, ?compatibility:PackageCompatibility) {
		this.root = root;
		this.source = source;
		this.resolvedRevision = resolvedRevision;
		this.checksum = checksum;
		this.compatibility = compatibility;
	}
}
