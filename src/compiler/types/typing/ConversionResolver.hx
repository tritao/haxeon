package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

/** Applies the conversion plan selected by the compilation's type relations. */
class ConversionResolver {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	public function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		if (value.type == TNever)
			return new TypedExpression(value.expression, expected, value.span);
		if (session.tolerant && TypeRelations.containsRecovery(value.type))
			return new TypedExpression(value.expression, expected, value.span);
		switch expected {
			case TNullable(element) if (value.type != TNull && !isNullable(value.type)):
				var converted = coerce(value, element, context, code);
				return new TypedExpression(TNullableWrap(converted), expected, value.span);
			default:
		}
		return switch session.relations.conversion(value.type, expected) {
			case Identity: value;
			case IntToFloat:
				new TypedExpression(TIntToFloat(value), TFloat, value.span);
			case IntToInt64:
				new TypedExpression(TIntToInt64(value), TInt64, value.span);
			case FromDynamic:
				new TypedExpression(TCast(value), expected, value.span);
			case ReferenceCast:
				functionAdapter(value, expected, value.span);
			case AbstractCast:
				var conversion = abstractFromFunction(value.type, expected);
				conversion == null ? session.representation.boundaryCast(value,
					expected) : new TypedExpression(TCall(conversion, [value]), expected, value.span);
			case ToDynamic:
				new TypedExpression(TToDynamic(value), expected, value.span);
			case ToInterface(name):
				new TypedExpression(TToInterface(value, name), expected, value.span);
			case WrapNullable:
				new TypedExpression(TNullableWrap(value), expected, value.span);
			case UnwrapNullable:
				new TypedExpression(TCast(value), expected, value.span);
			case Incompatible:
				fail(code, 'Type mismatch for $context', value.span);
				value;
		};
	}

	function abstractFromFunction(actual:CompilerType, expected:CompilerType):Null<String> {
		return switch expected {
			case TAbstract(name, arguments, _):
				var declaration = session.declarations.abstracts.get(name);
				if (declaration == null)
					return null;
				var substitutions = session.representation.typeParameterSubstitutions(declaration.typeParameters, arguments);
				for (method in declaration.methods) {
					if (!method.isStatic || method.arguments.length != 1)
						continue;
					var metadata = method.metadata;
					if (metadata == null)
						continue;
					var isFrom = false;
					for (entry in metadata)
						if (entry.name == "from")
							isFrom = true;
					if (isFrom
						&& TypeRelations.equals(actual, session.declarations.resolve(method.arguments[0].type, method.span, substitutions)))
						return name + "." + method.name;
				}
				null;
			default: null;
		};
	}

	public function adaptFunction(value:TypedExpression, expected:CompilerType, span:SourceSpan):TypedExpression
		return functionAdapter(value, expected, span);

	function functionAdapter(value:TypedExpression, expected:CompilerType, span:SourceSpan):TypedExpression {
		var sourceSignature = expectedFunctionType(value.type),
			targetSignature = expectedFunctionType(expected);
		if (sourceSignature == null || targetSignature == null)
			return new TypedExpression(TCast(value), expected, span);
		var sourceArguments = sourceSignature.arguments,
			sourceResult = sourceSignature.result,
			targetArguments = targetSignature.arguments,
			targetResult = targetSignature.result;
		if (sourceArguments.length != targetArguments.length || TypeRelations.equals(value.type, expected))
			return new TypedExpression(TCast(value), expected, span);
		var contextName = session.currentContext.name, adapterId = session.functionAdapterCounter++,
			adapterName = '$' + 'function-adapter:$contextName:$adapterId', environmentName = '$' + 'function-adapter-env:$contextName:$adapterId',
			captureName = '__adapted_callable', arguments = [
				for (index in 0...targetArguments.length)
					{
						name: '$' + 'adapter_arg_$index',
						type: targetArguments[index]
					}
			], captures:Array<TypedCapture> = [
				{
					field: captureName,
					bindingId: captureName,
					type: value.type,
					storageType: value.type,
					source: CaptureExpression(value)
				}
			], callable = new TypedExpression(TCaptured(captureName), value.type, span, false, null, value.type), callArguments = [
				for (index in 0...arguments.length)
					adaptFunctionValue(new TypedExpression(TLocal(arguments[index].name), arguments[index].type, span), sourceArguments[index], span)
			], call = new TypedExpression(TClosureCall(callable, callArguments), sourceResult, span), statements:Array<TypedStatement> = [];
		if (targetResult == TVoid) {
			statements.push(TExpression(call, span));
			statements.push(TReturnVoid(span));
		} else if (sourceResult != TVoid)
			statements.push(TReturn(adaptFunctionValue(call, targetResult, span), span));
		else
			return new TypedExpression(TCast(value), expected, span);
		session.closureConversion.addEnvironment(environmentName, captures);
		session.closureConversion.addFunction({
			name: adapterName,
			genericOrigin: contextName,
			owner: environmentName,
			isStatic: false,
			isConstructor: false,
			arguments: arguments,
			result: targetResult,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: span
		});
		return new TypedExpression(TLambda(adapterName, environmentName, captures), expected, span);
	}

	function adaptFunctionValue(value:TypedExpression, target:CompilerType, span:SourceSpan):TypedExpression {
		if (TypeRelations.equals(value.type, target))
			return value;
		if (value.type == TInt && target == TFloat)
			return new TypedExpression(TIntToFloat(value), TFloat, span);
		if (value.type == TInt && target == TInt64)
			return new TypedExpression(TIntToInt64(value), TInt64, span);
		if (value.type == TFloat && target == TInt)
			return new TypedExpression(TFloatToInt(value), TInt, span);
		return new TypedExpression(TCast(value), target, span);
	}

	static function expectedFunctionType(type:Null<CompilerType>):Null<{arguments:Array<CompilerType>, result:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result): {arguments: arguments, result: result};
			case TNullable(inner): expectedFunctionType(inner);
			default: null;
		};
	}

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
