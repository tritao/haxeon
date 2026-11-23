package project;

/** Result of acquisition, including the immutable identity used by a lockfile. */
class AcquiredSource {
	public final root:String;
	public final source:PackageSource;
	public final resolvedRevision:Null<String>;
	public final checksum:Null<String>;
	public final compatibility:Null<PackageCompatibility>;

	/** The package's manifest when it is not the file in `root`: a live registry package's, as publishing would write it. */
	public final manifest:Null<PackageManifest>;

	/**
	 * A registry package resolved live from its directory (a checkout's haxeon registry): nothing to verify, and a lockfile's entry
	 * for it is kept as it is.
	 */
	public final live:Bool;

	public function new(root:String, source:PackageSource, ?resolvedRevision:String, ?checksum:String,
			?compatibility:PackageCompatibility, ?manifest:PackageManifest, live:Bool = false) {
		this.root = root;
		this.source = source;
		this.resolvedRevision = resolvedRevision;
		this.checksum = checksum;
		this.compatibility = compatibility;
		this.manifest = manifest;
		this.live = live;
	}
}
