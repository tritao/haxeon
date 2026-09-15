package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.analysis.Scope;
import compiler.types.typing.CallResolver.ArgumentTypeCallback;
import compiler.types.typing.CallResolver.DefaultExpressionCallback;
import compiler.types.typing.CallResolver.TypeExpressionCallback;

typedef GenericCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef GenericCoerceArgumentsCallback = (Array<TypedExpression>, Array<CompilerType>, String) -> Array<TypedExpression>;
typedef SpecializedFunctionTyper = (AstFunction, Null<String>, Bool, Null<Map<String, CompilerType>>, Null<String>, Null<CompilerType>) -> TypedFunction;

/** Resolves generic substitutions and requests/reuses emitted function specializations. */
class GenericInstantiation {
	final session:TypingSession;
	final typeExpression:TypeExpressionCallback;
	final coerce:GenericCoerceCallback;
	final coerceArguments:GenericCoerceArgumentsCallback;
	final argumentType:ArgumentTypeCallback;
	final typeDefaultExpression:DefaultExpressionCallback;
	final posInfosExpression:SourceSpan->AstExpression;
	final typeFunction:SpecializedFunctionTyper;

	public function new(session:TypingSession, typeExpression:TypeExpressionCallback, coerce:GenericCoerceCallback,
			coerceArguments:GenericCoerceArgumentsCallback, argumentType:ArgumentTypeCallback, typeDefaultExpression:DefaultExpressionCallback,
			posInfosExpression:SourceSpan->AstExpression, typeFunction:SpecializedFunctionTyper) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
		this.coerceArguments = coerceArguments;
		this.argumentType = argumentType;
		this.typeDefaultExpression = typeDefaultExpression;
		this.posInfosExpression = posInfosExpression;
		this.typeFunction = typeFunction;
	}

	public function specialize(baseName:String, fn:AstFunction, arguments:Array<TypedExpression>, span:SourceSpan, scope:Scope, owner:Null<String>,
			isStatic:Bool, ?presetSubstitutions:Map<String, CompilerType>, ?receiver:TypedExpression):TypedExpression {
		var required = fn.arguments.length;
		while (required > 0 && fn.arguments[required - 1].optional == true)
			required--;
		if (arguments.length < required || arguments.length > fn.arguments.length) {
			var expected = required == fn.arguments.length ? '$required' : '$required to ${fn.arguments.length}';
			if (!session.tolerant)
				fail("E1008", 'Function "$baseName" expects $expected arguments, got ${arguments.length}', span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1008",
				'Function "$baseName" expects $expected arguments, got ${arguments.length}', span));
		}
		var substitutions:Map<String, CompilerType> = presetSubstitutions == null ? [] : [for (parameter => type in presetSubstitutions) parameter => type],
			parameters = functionTypeParameters(fn);
		for (i in 0...arguments.length)
			if (i < fn.arguments.length)
				inferTypeParameters(fn.arguments[i].type, arguments[i].type, parameters, substitutions, arguments[i].span);
		for (parameter in parameters)
			if (!substitutions.exists(parameter)) {
				if (!session.tolerant)
					fail("E1003", 'Cannot infer generic type parameter "$parameter" for "$baseName"', span);
				substitutions.set(parameter, TUnknown);
			}
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints) {
				var actual = requiredMapValue(substitutions, constraint.parameter),
					expected = session.declarations.resolve(constraint.type, constraint.span, substitutions);
				if (!session.relations.isAssignable(actual, expected))
					fail("E1003", 'Type argument for "${constraint.parameter}" does not satisfy constraint "${SemanticSignature.type(expected)}"', span);
			}
		var semanticExpected = [for (argument in fn.arguments) argumentType(argument, substitutions)];
		for (index in arguments.length...fn.arguments.length) {
			var parameter = fn.arguments[index],
				defaultValue = parameter.defaultValue,
				expected = semanticExpected[index];
			if (CallResolver.isPosInfosParameter(parameter))
				arguments.push(recoverOrCoerce(typeExpression(posInfosExpression(span), scope, expected, false), expected,
					'position argument ${index + 1} to "$baseName"', "E1009"));
			else if (defaultValue == null)
				arguments.push(recoverOrCoerce(new TypedExpression(TNullLiteral, TNull, span), expected,
					'default argument ${index + 1} to "$baseName"', "E1009"));
			else
				arguments.push(recoverOrCoerce(typeDefaultExpression(defaultValue, expected, baseName), expected,
					'default argument ${index + 1} to "$baseName"', "E1009"));
		}
		var semanticArguments = if (!session.tolerant) coerceArguments(arguments, semanticExpected, baseName) else [
			for (index in 0...arguments.length)
				index < semanticExpected.length
					? recoverOrCoerce(arguments[index], semanticExpected[index], 'argument ${index + 1} to "$baseName"', "E1009")
					: arguments[index]
		],
			genericCall = session.representation.resolveGenericCall(fn, substitutions, semanticArguments, argumentType),
			genericRepresentation = genericCall.representation,
			representationSubstitutions = genericRepresentation.substitutions,
			specializationPolicies = genericRepresentation.policies,
			representationResult = genericCall.result.physical,
			representationArguments = genericCall.typeArguments,
			specialization = session.genericSpecializations.request(baseName, representationArguments, specializationPolicies),
			result = genericCall.result.semantic,
			typed = genericCall.arguments;
		var representationReceiver:Null<CompilerType> = null;
		if (receiver != null)
			representationReceiver = session.declarations.abstracts.exists(requiredString(owner)) ? abstractReceiverType(requiredString(owner),
				representationSubstitutions) : receiver.type;
		if (!session.emittedGenericBodies.exists(specialization.name)) {
			session.emittedGenericBodies.set(specialization.name, true);
			session.closureConversion.addFunction(typeFunction(fn, owner, receiver == null ? isStatic : true, representationSubstitutions,
				specialization.name, representationReceiver));
		}
		if (receiver != null) {
			var receiverType = representationReceiver;
			if (receiverType == null)
				throw "Generic receiver representation was not resolved";
			typed.unshift(session.representation.boundaryCast(receiver, receiverType));
		}
		var call = new TypedExpression(TCall(specialization.name, typed), representationResult, span);
		return session.representation.boundaryCast(call, result);
	}

	function recoverOrCoerce(value:TypedExpression, expected:CompilerType, context:String, code:String):TypedExpression {
		if (!session.tolerant)
			return coerce(value, expected, context, code);
		try {
			return coerce(value, expected, context, code);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, compiler.service.CancellationError))
				throw error;
			if (Std.isOfType(error, CompileError)) {
				var compileError:CompileError = cast error;
				session.rememberRecoveryDiagnostic(compileError.diagnostic);
			}
			return new TypedExpression(value.expression, TError, value.span);
		}
	}

	public function inferTypeParameters(pattern:AstType, actual:CompilerType, parameters:Array<String>, substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void
		switch pattern {
			case NamedType(name) if (parameters.indexOf(name) >= 0):
				if (substitutions.exists(name)) {
					var previous = requiredMapValue(substitutions, name);
					if (previous == TDynamic)
						substitutions.set(name, actual);
					else if (actual != TDynamic && !TypeRelations.equals(previous, actual)) {
						if (session.relations.isAssignable(actual, previous))
							substitutions.set(name, actual);
						else if (!session.relations.isAssignable(previous, actual))
							fail("E1003", 'Conflicting types inferred for generic parameter "$name"', span);
					}
				} else
					substitutions.set(name, actual);
			case ArrayType(element):
				switch actual {
					case TArray(actualElement): inferTypeParameters(element, actualElement, parameters, substitutions, span);
					default:
				}
			case MapType(key, value):
				switch actual {
					case TMap(actualKey, actualValue):
						inferTypeParameters(key, actualKey, parameters, substitutions, span);
						inferTypeParameters(value, actualValue, parameters, substitutions, span);
					default:
				}
			case NullableType(element):
				switch actual {
					case TNullable(actualElement): inferTypeParameters(element, actualElement, parameters, substitutions, span);
					default:
				}
			case AppliedType(name, patternArguments):
				switch actual {
					case TIterator(actualElement) if (name == "Iterator" && patternArguments.length == 1):
						inferTypeParameters(patternArguments[0], actualElement, parameters, substitutions, span);
					case TInstance(_, actualName, actualArguments) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters, substitutions, span);
					case TAbstract(actualName, actualArguments, _) if (actualName == name
						&& patternArguments.length == actualArguments.length):
						for (index in 0...patternArguments.length)
							inferTypeParameters(patternArguments[index], actualArguments[index], parameters, substitutions, span);
					default:
				}
			case FunctionType(patternArguments, patternResult):
				switch actual {
					case TFunction(actualArguments, actualResult) if (patternArguments.length == actualArguments.length):
						for (i in 0...patternArguments.length)
							inferTypeParameters(patternArguments[i], actualArguments[i], parameters, substitutions, span);
						inferTypeParameters(patternResult, actualResult, parameters, substitutions, span);
					default:
				}
			case AnonymousType(patternFields):
				switch actual {
					case TAnonymous(_, actualFields):
						for (field in patternFields) {
							var actualField = anonymousField(actualFields, field.name);
							if (actualField != null)
								inferTypeParameters(field.type, actualField.type, parameters, substitutions, span);
						}
					default:
				}
			default:
		}

	function abstractReceiverType(name:String, substitutions:Map<String, CompilerType>):CompilerType {
		var decl = requiredMapValue(session.declarations.abstracts, name), arguments = [
			for (parameter in decl.typeParameters)
				requiredMapValue(substitutions, parameter)
		], representation = session.representation.semanticType(decl.underlying, decl.span, substitutions);
		return TAbstract(name, arguments, representation);
	}

	static function anonymousField(fields:Null<Array<compiler.types.Type.AnonymousField>>, name:String):Null<compiler.types.Type.AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	static function functionTypeParameters(fn:AstFunction):Array<String>
		return fn.typeParameters == null ? [] : fn.typeParameters;

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	static function requiredString(value:Null<String>):String {
		if (value == null)
			throw "Expected string";
		return value;
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
