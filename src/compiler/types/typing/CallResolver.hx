package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.types.Type.CompilerType;
import compiler.types.analysis.Scope;
import compiler.types.TypedAst.TypedExpression;

typedef TypeExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef CoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ArgumentTypeCallback = (AstArgument, Null<Map<String, CompilerType>>) -> CompilerType;
typedef DefaultExpressionCallback = (AstExpression, CompilerType, String) -> TypedExpression;
typedef InferTypeParametersCallback = (AstType, CompilerType, Array<String>, Map<String, CompilerType>, SourceSpan) -> Void;

/** Resolves source arguments against the selected callable's parameter types. */
class CallResolver {
	final session:TypingSession;
	final typeExpression:TypeExpressionCallback;
	final coerce:CoerceCallback;
	final argumentType:ArgumentTypeCallback;
	final posInfosExpression:SourceSpan->AstExpression;
	final typeDefaultExpression:DefaultExpressionCallback;
	final functionTypeParameters:AstFunction->Array<String>;
	final inferTypeParameters:InferTypeParametersCallback;
	final inheritanceName:AstType->String;

	public function new(session:TypingSession, typeExpression:TypeExpressionCallback, coerce:CoerceCallback, argumentType:ArgumentTypeCallback,
			posInfosExpression:SourceSpan->AstExpression, typeDefaultExpression:DefaultExpressionCallback, functionTypeParameters:AstFunction->Array<String>,
			inferTypeParameters:InferTypeParametersCallback, inheritanceName:AstType->String) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
		this.argumentType = argumentType;
		this.posInfosExpression = posInfosExpression;
		this.typeDefaultExpression = typeDefaultExpression;
		this.functionTypeParameters = functionTypeParameters;
		this.inferTypeParameters = inferTypeParameters;
		this.inheritanceName = inheritanceName;
	}

	public function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output:Array<TypedExpression> = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"', "E1009"));
		return output;
	}

	public function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope, name:String):Array<TypedExpression> {
		var typed = [
			for (i in 0...arguments.length)
				typeExpression(arguments[i], scope, expected[i], false)
		];
		return coerceArguments(typed, expected, name);
	}

	public function typeDeclaredCallArguments(arguments:Array<AstExpression>, parameters:Array<AstArgument>, scope:Scope, name:String, span:SourceSpan,
			?substitutions:Map<String, CompilerType>):Array<TypedExpression> {
		var required = parameters.length;
		while (required > 0 && parameters[required - 1].optional == true)
			required--;
		if (arguments.length < required || arguments.length > parameters.length) {
			var expected = required == parameters.length ? '$required' : '$required to ${parameters.length}';
			fail("E1008", 'Function "$name" expects $expected arguments, got ${arguments.length}', span);
		}
		var typed:Array<TypedExpression> = [];
		for (i in 0...arguments.length) {
			var supplied = argumentType(parameters[i], substitutions),
				value = typeExpression(arguments[i], scope, supplied, false);
			typed.push(coerce(value, supplied, 'argument ${i + 1} to "$name"', "E1009"));
		}
		for (i in arguments.length...parameters.length) {
			var parameter = parameters[i],
				expected = argumentType(parameter, substitutions),
				defaultValue = parameter.defaultValue;
			if (isPosInfosParameter(parameter))
				typed.push(coerce(typeExpression(posInfosExpression(span), scope, expected, false), expected, 'position argument ${i + 1} to "$name"',
					"E1009"));
			else if (defaultValue == null)
				typed.push(coerce(new TypedExpression(TNullLiteral, TNull, span), expected, 'default argument ${i + 1} to "$name"', "E1009"));
			else
				typed.push(coerce(typeDefaultExpression(defaultValue, expected, name), expected, 'default argument ${i + 1} to "$name"', "E1009"));
		}
		return coerceArguments(typed, [for (parameter in parameters) argumentType(parameter, substitutions)], name);
	}

	public function typeGenericCallArguments(fn:AstFunction, arguments:Array<AstExpression>, scope:Scope, span:SourceSpan):{
		arguments:Array<TypedExpression>,
		substitutions:Map<String, CompilerType>
	} {
		var parameters = functionTypeParameters(fn),
			substitutions:Map<String, CompilerType> = [],
			typed:Array<TypedExpression> = [];
		for (index in 0...arguments.length) {
			var expected:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions))
				expected = session.declarations.resolve(fn.arguments[index].type, fn.arguments[index].span, substitutions);
			var argument = typeExpression(arguments[index], scope, expected, expected != null);
			inferTypeParameters(fn.arguments[index].type, argument.type, parameters, substitutions, argument.span);
			typed.push(argument);
		}
		return {arguments: typed, substitutions: substitutions};
	}

	public function findMethod(className:String, name:String):Null<SemanticMethodInfo> {
		var results:Array<SemanticMethodInfo> = [];
		findMethods(className, name, results);
		return results.length == 0 ? null : results[0];
	}

	function findMethods(className:String, name:String, results:Array<SemanticMethodInfo>):Void {
		if (results.length > 0)
			return;
		var key = className + "." + name;
		if (session.methodInfo.exists(key)) {
			results.push(requiredMapValue(session.methodInfo, key));
			return;
		}
		if (session.classDecls.exists(className)) {
			var base = requiredMapValue(session.classDecls, className).base;
			if (base != null)
				findMethods(inheritanceName(base), name, results);
			return;
		}
		if (session.interfaceDecls.exists(className))
			for (base in requiredMapValue(session.interfaceDecls, className).bases)
				findMethods(inheritanceName(base), name, results);
	}

	static function allTypeParametersBound(parameters:Array<String>, substitutions:Map<String, CompilerType>):Bool {
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				return false;
		return true;
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	public static function isPosInfosParameter(argument:AstArgument):Bool
		return argument.optional == true && switch argument.type {
			case NamedType("haxe.PosInfos"): true;
			default: false;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
