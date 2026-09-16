package compiler.semantic;

import compiler.service.CancellationToken;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;
import compiler.semantic.SemanticIndex.SemanticSignatureInfo;

/**
	Read-only recovery queries over a frozen semantic traversal result.

	Recovery lookup algorithms still share implementation with the builder, but
	the mutable construction object is hidden behind this boundary. The builder
	guards all construction-side mutation after publication, so editor queries
	can safely retain this view for the lifetime of an immutable index.
*/
class SemanticIndexRecoveryQuery {
	final builder:SemanticIndexBuilder;

	public function new(builder:SemanticIndexBuilder) {
		if (!builder.isFrozen)
			throw "Recovery query requires a frozen semantic index builder";
		this.builder = builder;
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return builder.completionContext(position, qualifier, token);

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo>
		return builder.recoveredSignature(name, receiverType);

	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo>
		return builder.callableSignature(type, name);
}
