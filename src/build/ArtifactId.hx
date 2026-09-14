package build;

import build.Artifact.ArtifactKind;

/** Stable logical identity; it intentionally contains no filesystem path. */
class ArtifactId {
	public final packageId:String;
	public final kind:ArtifactKind;
	public final target:Target;
	public final variant:String;

	public function new(packageId:String, kind:ArtifactKind, target:Target, ?variant:String = "") {
		this.packageId = packageId;
		this.kind = kind;
		this.target = target;
		this.variant = variant;
	}

	public function key():String
		return '${packageId}:${Artifact.kindName(kind)}:${target.toString()}:${variant}';

	public function equals(other:ArtifactId):Bool
		return key() == other.key();

	public function toString():String
		return '${packageId}:${Artifact.kindName(kind)}[${target.toString()}]${variant == "" ? "" : "#" + variant}';
}
