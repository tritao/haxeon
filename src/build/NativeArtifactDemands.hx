package build;

import build.Artifact.ArtifactKind;

class NativeArtifactDemands {
	public static function includes(demand:NativeArtifactDemand, kind:ArtifactKind):Bool
		return switch demand {
			case None: false;
			case Static: kind == ArtifactKind.NativeStaticLibrary;
			case Shared: kind == ArtifactKind.NativeSharedLibrary;
			case Both: kind == ArtifactKind.NativeStaticLibrary || kind == ArtifactKind.NativeSharedLibrary;
		};
}
