package compiler.semantic;

import compiler.service.CancellationToken;
import compiler.Source.SourceSpan;
import compiler.syntax.Token;
import compiler.types.DeclarationIndex;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticCompletionContextKind;
import compiler.semantic.SemanticIndex.SemanticCompletionLocal;
import compiler.semantic.SemanticIndex.SemanticRecoveredTypeParameterScope;

typedef SemanticCompletionFacts = {
	final locals:Array<SemanticCompletionLocal>;
	final typeParameters:Array<SemanticRecoveredTypeParameterScope>;
	final receivers:Array<{span:SourceSpan, type:CompilerType}>;
	final expectedTypes:Array<{span:SourceSpan, type:CompilerType}>;
	final qualifiers:Array<{name:String, span:SourceSpan, type:CompilerType}>;
	final classBases:Map<String, CompilerType>;
	final declarations:DeclarationIndex;
	final tokens:Array<Token>;
}

/** Builds completion context from an immutable semantic-facts view. */
class SemanticCompletionQuery {
	public static function build(facts:SemanticCompletionFacts, position:Int, ?qualifier:String,
			?cancellation:CancellationToken):SemanticCompletionContext {
		var visible:Map<String, SemanticCompletionLocal> = [];
		for (local in facts.locals) {
			if (cancellation != null)
				cancellation.check();
			if (position >= local.declaration.start && position <= local.scope.end) {
				var existing = visible.get(local.name);
				if (existing == null
					|| local.depth > existing.depth
					|| (local.depth == existing.depth && local.declaration.start > existing.declaration.start))
					visible.set(local.name, local);
			}
		}
		var locals = [for (local in visible) local];
		locals.sort(function(left, right) return Reflect.compare(left.name, right.name));
		var typeParameters:Array<String> = [];
		for (candidate in facts.typeParameters)
			if (position >= candidate.span.start && position <= candidate.span.end && typeParameters.indexOf(candidate.name) < 0)
				typeParameters.push(candidate.name);
		typeParameters.sort(Reflect.compare);
		var overrideContext = CompletionContextSyntax.isOverrideContext(facts.tokens, position, cancellation),
			receiver:Null<CompilerType> = null;
		if (qualifier != null) {
			if (qualifier == "this")
				for (candidate in facts.receivers) {
					if (cancellation != null)
						cancellation.check();
					if (position >= candidate.span.start && position <= candidate.span.end)
						receiver = candidate.type;
				}
			if (receiver == null)
				for (local in locals) {
					if (cancellation != null)
						cancellation.check();
					if (local.name == qualifier)
						receiver = local.type;
				}
		}
		if (receiver == null && overrideContext)
			for (owner in facts.declarations.classes)
				if (position >= owner.span.start && position <= owner.span.end && facts.classBases.exists(owner.name)) {
					receiver = facts.classBases.get(owner.name);
					break;
				}
		if (receiver == null && qualifier != null) {
			var selectedQualifier:Null<{name:String, span:SourceSpan, type:CompilerType}> = null;
			for (candidate in facts.qualifiers) {
				if (cancellation != null)
					cancellation.check();
				if (candidate.name != qualifier
					|| position < candidate.span.start
					|| position > candidate.span.end + 1)
					continue;
				if (selectedQualifier == null
					|| candidate.span.end - candidate.span.start < selectedQualifier.span.end - selectedQualifier.span.start
					|| candidate.span.end - candidate.span.start == selectedQualifier.span.end - selectedQualifier.span.start
					&& candidate.span.start > selectedQualifier.span.start)
					selectedQualifier = candidate;
			}
			if (selectedQualifier != null)
				receiver = selectedQualifier.type;
		}
		var expected:Null<CompilerType> = null, expectedWidth = 0x3fffffff;
		for (candidate in facts.expectedTypes) {
			if (cancellation != null)
				cancellation.check();
			if (position >= candidate.span.start && position <= candidate.span.end) {
				var width = candidate.span.end - candidate.span.start;
				if (width < expectedWidth) {
					expected = candidate.type;
					expectedWidth = width;
				}
			}
		}
		var kind = CompletionContextSyntax.isImportContext(facts.tokens, position, cancellation) ? SemanticCompletionContextKind.Import : qualifier != null
			? SemanticCompletionContextKind.Member : overrideContext ? SemanticCompletionContextKind.Override : expected != null
			&& CompletionContextSyntax.isObjectFieldContext(facts.tokens, position,
				cancellation) ? SemanticCompletionContextKind.ObjectField : CompletionContextSyntax.isTypeContext(facts.tokens, position,
				cancellation) ? SemanticCompletionContextKind.Type : expected != null
			&& CompletionContextSyntax.isPatternContext(facts.tokens, position,
				cancellation) ? SemanticCompletionContextKind.Pattern : expected != null ? SemanticCompletionContextKind.Argument : SemanticCompletionContextKind.Expression;
		return {
			locals: locals,
			typeParameters: typeParameters,
			receiver: receiver,
			expected: expected,
			kind: kind
		};
	}
}
