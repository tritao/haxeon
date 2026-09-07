package compiler.semantic;

/** Stable category explaining why a typed artifact had to be rebuilt. */
enum abstract InvalidationKind(String) {
	var SourceRevision = "source-revision";
	var BodyChanged = "body-changed";
	var SignatureChanged = "signature-changed";
	var StructuralDependency = "structural-dependency";
	var DependencySignature = "dependency-signature";
	var GenericOrigin = "generic-origin";
	var ModuleSemanticSnapshot = "module-semantic-snapshot";
}

typedef InvalidationReason = {
	final kind:InvalidationKind;

	/** Artifact or module which directly caused this invalidation. */
	final cause:String;

	final ?causeId:String;

	/** Dependency boundary crossed while propagating the invalidation. */
	final ?via:String;
}

typedef InvalidatedArtifact = {
	final artifact:String;
	final reasons:Array<InvalidationReason>;
}
