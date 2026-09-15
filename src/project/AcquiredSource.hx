package project;

/** Result of acquisition, including the immutable identity used by a lockfile. */
class AcquiredSource {
	public final root:String;
	public final source:PackageSource;
	public final resolvedRevision:Null<String>;

	public function new(root:String, source:PackageSource, ?resolvedRevision:String) {
		this.root = root;
		this.source = source;
		this.resolvedRevision = resolvedRevision;
	}
}
