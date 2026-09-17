package compiler.semantic;

import compiler.service.CancellationToken;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;
import compiler.semantic.SemanticIndex.SemanticSignatureInfo;
import compiler.semantic.SemanticCompletionQuery.SemanticCompletionFacts;

/**
	Read-only recovery queries over a frozen semantic traversal result.

	Completion and callable-signature queries consume copied facts. The
	receiver-aware recovered-signature resolver still shares implementation with
	the frozen builder until that algorithm is extracted as its own query state.
*/
class SemanticIndexRecoveryQuery {
	/** Remaining recovered-signature algorithms are extracted next. */
	final builder:SemanticIndexBuilder;
	final completionFacts:SemanticCompletionFacts;
	final recoveredFunctions:Map<String, AstFunction>;

	public function new(builder:SemanticIndexBuilder) {
		if (!builder.isFrozen)
			throw "Recovery query requires a frozen semantic index builder";
		this.builder = builder;
		recoveredFunctions = [];
		for (name => fn in builder.recoveredFunctions)
			recoveredFunctions.set(name, fn);
		completionFacts = {
			locals: [for (local in builder.completionLocals) {
				name: local.name,
				type: local.type,
				declaration: local.declaration,
				scope: local.scope,
				depth: local.depth
			}],
			typeParameters: [for (scope in builder.recoveredTypeParameterScopes) {
				name: scope.name,
				owner: scope.owner,
				span: scope.span
			}],
			receivers: [for (receiver in builder.functionReceivers) {span: receiver.span, type: receiver.type}],
			expectedTypes: [for (expected in builder.completionTypes) {span: expected.span, type: expected.type}],
			qualifiers: [for (qualifier in builder.recoveredQualifiers) {
				name: qualifier.name,
				span: qualifier.span,
				type: qualifier.type
			}],
			classBases: builder.recoveredClassBases.copy(),
			declarations: builder.declarations,
			tokens: builder.tokens.copy()
		};
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return SemanticCompletionQuery.build(completionFacts, position, qualifier, token);

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo> {
		// Direct function and constructor signatures do not require the mutable
		// recovery resolver. Keep these queries entirely on copied declarations;
		// inherited/generic receiver signatures use the compatibility resolver
		// until that richer algorithm gets its own immutable state.
		if (receiverType == null) {
			var fn = recoveredFunctions.get(name);
			if (fn == null)
				fn = recoveredFunctions.get(name + ".new");
			if (fn != null) {
				var parameters = [for (argument in fn.arguments)
					argument.name + ":" + displayAstType(argument.type)],
					labelName = name.lastIndexOf(".") < 0 ? name : name.substr(name.lastIndexOf(".") + 1),
					result = displayAstType(fn.result);
				return {
					label: labelName + "(" + parameters.join(",") + "):" + result,
					parameters: parameters,
					result: result
				};
			}
		}
		return builder.recoveredSignature(name, receiverType);
	}

	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo>
		return switch type {
			case TFunction(arguments, result):
				var parameters = [for (index in 0...arguments.length) "arg" + index + ":" + displayType(arguments[index])],
					resultName = displayType(result);
				{
					label: name + "(" + parameters.join(",") + "):" + resultName,
					parameters: parameters,
					result: resultName
				};
			case TNullable(element): callableSignature(element, name);
			default: null;
		};

	static function displayType(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TFloat: "Float";
			case TBool: "Bool";
			case TString: "String";
			case TVoid: "Void";
			case TArray(element): 'Array<${displayType(element)}>';
			case TIterator(element): 'Iterator<${displayType(element)}>';
			case TMap(key, value): 'Map<${displayType(key)},${displayType(value)}>';
			case TNullable(element): 'Null<${displayType(element)}>';
			case TTypeParameter(_, name): name;
			case TInstance(_, name, arguments): arguments.length == 0 ? name : name + "<" + [for (argument in arguments) displayType(argument)].join(",") + ">";
			case TFunction(arguments, result): "(" + [for (argument in arguments) displayType(argument)].join(",") + ")->" + displayType(result);
			default: Std.string(type);
		};

	static function displayAstType(type:AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NamedType(name): name;
			case AppliedType(name, arguments): name + "<" + [for (argument in arguments) displayAstType(argument)].join(",") + ">";
			case ArrayType(element): 'Array<${displayAstType(element)}>';
			case MapType(key, value): 'Map<${displayAstType(key)},${displayAstType(value)}>';
			case NullableType(element): 'Null<${displayAstType(element)}>';
			case FunctionType(arguments, result): "(" + [for (argument in arguments) displayAstType(argument)].join(",") + ")->" + displayAstType(result);
			case AnonymousType(fields): "{" + [for (field in fields) field.name + ":" + displayAstType(field.type)].join(",") + "}";
			default: Std.string(type);
		};
}
