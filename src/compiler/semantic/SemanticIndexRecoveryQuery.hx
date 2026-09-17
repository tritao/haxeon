package compiler.semantic;

import compiler.service.CancellationToken;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;
import compiler.semantic.SemanticIndex.SemanticSignatureInfo;
import compiler.semantic.SemanticCompletionQuery.SemanticCompletionFacts;

private typedef SemanticIndexRecoveryFacts = {
	final completionFacts:SemanticCompletionFacts;
	final directSignatures:Map<String, SemanticSignatureInfo>;
	final receiverSignatures:Map<String, SemanticSignatureInfo>;
}

/**
	Read-only recovery queries over a frozen semantic traversal result.

	The builder is used only while `fromBuilder()` materializes this state. The
	published query keeps no construction-time resolver or mutable traversal
	workspace reference.
*/
class SemanticIndexRecoveryQuery {
	final completionFacts:SemanticCompletionFacts;
	final directSignatures:Map<String, SemanticSignatureInfo>;
	final receiverSignatures:Map<String, SemanticSignatureInfo>;

	private function new(facts:SemanticIndexRecoveryFacts) {
		completionFacts = facts.completionFacts;
		directSignatures = facts.directSignatures;
		receiverSignatures = facts.receiverSignatures;
	}

	public static function fromBuilder(builder:SemanticIndexBuilder):SemanticIndexRecoveryQuery {
		if (!builder.isFrozen)
			throw "Recovery query requires a frozen semantic index builder";
		var recoveredFunctions:Map<String, AstFunction> = [];
		for (name => fn in builder.recoveredFunctions)
			recoveredFunctions.set(name, fn);
		var completionFacts:SemanticCompletionFacts = {
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
			classes: [for (name => declaration in builder.declarations.classes) {name: name, span: declaration.span}],
			tokens: builder.tokens.copy()
		};
		var directSignatures:Map<String, SemanticSignatureInfo> = [];
		for (name => fn in recoveredFunctions) {
			var signature = signatureFromFunction(name, fn);
			directSignatures.set(name, signature);
			if (StringTools.endsWith(name, ".new")) {
				var constructorName = name.substr(0, name.length - ".new".length);
				if (!directSignatures.exists(constructorName))
					directSignatures.set(constructorName, signature);
			}
		}
		var receiverSignatures:Map<String, SemanticSignatureInfo> = [];
		var receiverTypes:Array<CompilerType> = [], seenReceiverTypes:Map<String, Bool> = [];
		for (receiver in completionFacts.receivers)
			addReceiverType(receiverTypes, seenReceiverTypes, receiver.type);
		for (local in completionFacts.locals)
			addReceiverType(receiverTypes, seenReceiverTypes, local.type);
		for (qualifier in completionFacts.qualifiers)
			addReceiverType(receiverTypes, seenReceiverTypes, qualifier.type);
		for (base in completionFacts.classBases)
			addReceiverType(receiverTypes, seenReceiverTypes, base);
		var names:Array<String> = [for (name in recoveredFunctions.keys()) name];
		names.sort(Reflect.compare);
		var memberNames:Array<String> = [];
		for (name in names) {
			var separator = name.lastIndexOf(".");
			if (separator > 0) {
				var member = name.substr(separator + 1);
				if (memberNames.indexOf(member) < 0)
					memberNames.push(member);
			}
		}
		memberNames.sort(Reflect.compare);
		var methodPresence:Map<String, Bool> = [];
		for (receiverType in receiverTypes) {
			var owner = receiverOwner(receiverType);
			if (owner == null)
				continue;
			for (member in memberNames)
				if (hasRecoveredMethod(builder, owner, member, [], methodPresence)) {
					var signature = builder.recoveredSignature(owner + "." + member, receiverType);
					if (signature != null)
						receiverSignatures.set(signatureKey(owner + "." + member, receiverType), copySignature(signature));
				}
			for (name in names) {
				var separator = name.lastIndexOf(".");
				if (separator < 1)
					continue;
				var declarationOwner = name.substring(0, separator),
					member = name.substr(separator + 1);
				if (declarationOwner != owner && hasRecoveredMethod(builder, declarationOwner, member, [], methodPresence)) {
					var signature = builder.recoveredSignature(name, receiverType);
					if (signature != null)
						receiverSignatures.set(signatureKey(name, receiverType), copySignature(signature));
				}
			}
		}
		return new SemanticIndexRecoveryQuery({
			completionFacts: completionFacts,
			directSignatures: directSignatures,
			receiverSignatures: receiverSignatures
		});
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return SemanticCompletionQuery.build(completionFacts, position, qualifier, token);

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo> {
		// Direct function and constructor signatures do not require receiver
		// materialization and can be rendered directly from copied declarations.
		if (receiverType == null) {
			var direct = directSignatures.get(name);
			if (direct == null)
				direct = directSignatures.get(name + ".new");
			if (direct != null)
				return copySignature(direct);
		}
		if (receiverType != null) {
			var cached = receiverSignatures.get(signatureKey(name, receiverType));
			if (cached != null)
				return copySignature(cached);
		}
		// The published recovery query is intentionally conservative for a
		// receiver type which was not present in the editor facts used to build
		// this snapshot. A later edit will publish a new materialized query.
		return null;
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

	static function addReceiverType(result:Array<CompilerType>, seen:Map<String, Bool>, type:CompilerType):Void {
		var key = Std.string(type);
		if (!seen.exists(key)) {
			seen.set(key, true);
			result.push(type);
		}
	}

	static function receiverOwner(type:CompilerType):Null<String>
		return switch type {
			case TNullable(element): receiverOwner(element);
			case TInstance(_, name, _), TAbstract(name, _, _): name;
			default: null;
		};

	static function hasRecoveredMethod(builder:SemanticIndexBuilder, owner:String, member:String, visiting:Array<String>, memo:Map<String, Bool>):Bool {
		if (visiting.indexOf(owner) >= 0)
			return false;
		var key = owner + "\u0000" + member,
			cached = memo.get(key);
		if (cached != null)
			return cached;
		var nextVisiting = visiting.concat([owner]),
			classDecl = builder.recoveredClassDeclaration(owner);
		if (classDecl != null) {
			for (method in classDecl.methods)
				if (method.name == member) {
					memo.set(key, true);
					return true;
				}
			if (classDecl.base != null) {
				var resolvedBase = builder.recoveredClassBases.get(owner),
					base = resolvedBase == null ? null : receiverOwner(resolvedBase);
				if (base == null)
					base = astTypeOwner(classDecl.base);
				if (base != null && hasRecoveredMethod(builder, base, member, nextVisiting, memo)) {
					memo.set(key, true);
					return true;
				}
			}
			for (interfaceType in classDecl.interfaces) {
				var interfaceOwner = astTypeOwner(interfaceType);
				if (interfaceOwner != null && hasRecoveredMethod(builder, interfaceOwner, member, nextVisiting, memo)) {
					memo.set(key, true);
					return true;
				}
			}
		}
		var interfaceDecl = builder.recoveredInterfaceDeclaration(owner);
		if (interfaceDecl != null) {
			for (method in interfaceDecl.methods)
				if (method.name == member) {
					memo.set(key, true);
					return true;
				}
			for (baseType in interfaceDecl.bases) {
				var base = astTypeOwner(baseType);
				if (base != null && hasRecoveredMethod(builder, base, member, nextVisiting, memo)) {
					memo.set(key, true);
					return true;
				}
			}
		}
		var abstractDecl = builder.recoveredAbstractDeclaration(owner);
		if (abstractDecl != null)
			for (method in abstractDecl.methods)
				if (method.name == member) {
					memo.set(key, true);
					return true;
				}
		memo.set(key, false);
		return false;
	}

	static function astTypeOwner(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};

	static function signatureKey(name:String, receiverType:CompilerType):String
		return name + "\u0000" + Std.string(receiverType);

	static function signatureFromFunction(name:String, fn:AstFunction):SemanticSignatureInfo {
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

	static function copySignature(signature:SemanticSignatureInfo):SemanticSignatureInfo
		return {
			label: signature.label,
			parameters: signature.parameters.copy(),
			result: signature.result
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
