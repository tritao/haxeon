package build;

/** Native outputs requested by a build consumer. */
enum NativeArtifactDemand {
	None;
	Static;
	Shared;
	Both;
}
