package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.IterationProtocol;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;

/** Applies the conversion plan selected by the compilation's type relations. */
class ConversionResolver {
	final session:TypingSession;

	public function new(session:TypingSession)
		this.session = session;

	/** A Never value takes the expected type; a block's value is its result, so the result takes it too. */
	static function neverAs(value:TypedExpression, expected:CompilerType):TypedExpression
		return switch value.expression {
			case TBlockExpression(statements, result) if (result.type == TNever):
				new TypedExpression(TBlockExpression(statements, neverAs(result, expected)), expected, value.span);
			default:
				new TypedExpression(value.expression, expected, value.span);
		};

	public function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		if (value.type == TNever)
			return neverAs(value, expected);
		if (value.type == TDynamic && anonymousTarget(expected) != null)
			return dynamicStructure(value, expected);
		if (IterationProtocol.name(expected) != null && value.type != TNull && !TypeRelations.equals(value.type, expected)) {
			if (!session.relations.isAssignable(value.type, expected))
				fail(code, 'Type mismatch for $context: iteration requires compatible iterator(), hasNext():Bool and next() methods', value.span);
			return iterationAdapter(value, expected);
		}
		switch expected {
			// A Dynamic converts to a nullable by one cast, below. Converting it to the element first would turn a null into a zero.
			case TNullable(element) if (value.type != TNull && value.type != TDynamic && !isNullable(value.type)):
				var converted = coerce(value, element, context, code);
				return new TypedExpression(TNullableWrap(converted), expected, value.span);
			default:
		}
		return switch session.relations.conversion(value.type, expected) {
			case Identity: ValueCopy.bind(session, value, expected);
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
				// A dynamic box stores a pointer, not an inline copy. Own a value-class payload before boxing it.
				new TypedExpression(TToDynamic(ValueCopy.bind(session, value, value.type)), expected, value.span);
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

	static function anonymousTarget(type:CompilerType):Null<CompilerType>
		return switch type {
			case TAnonymous(_, _): type;
			case TNullable(element): anonymousTarget(element);
			default: null;
		};

	/** Array casts remain storage views; only arrays inside a record copy need element conversion. */
	static function structuralCopyTarget(type:CompilerType):Null<CompilerType>
		return switch type {
			case TAnonymous(_, _): type;
			case TArray(element) if (structuralCopyTarget(element) != null): type;
			case TNullable(element): structuralCopyTarget(element);
			default: null;
		};

	/** Dynamic records have no nominal $anon identity. Check and copy their fields at the boundary. */
	function dynamicStructure(value:TypedExpression, expected:CompilerType):TypedExpression {
		var target = structuralCopyTarget(expected);
		if (target == null)
			throw "Expected anonymous conversion target";
		var name = switch target {
			case TAnonymous(name, _): name;
			default: compiler.semantic.SemanticSignature.type(target);
		};
		var origin = session.currentContext.name, span = value.span;
		var helper = "$dynamic-structure:" + origin + ":" + name;
		if (session.dynamicStructureConversions.get(helper) == true)
			fail("E1016", "Recursive Dynamic to anonymous structure conversion is not supported; convert the recursive fields explicitly", span);
		if (!session.dynamicStructureConversions.exists(helper)) {
			// Reject recursive copies: cyclic Dynamic input cannot be copied without an identity table.
			session.dynamicStructureConversions.set(helper, true);
			session.runtimeDependencyTracker.record(origin, "Reflect");
			new AnonymousTypeRegistry(session).register(target);
			var source = new TypedExpression(TLocal("source"), TDynamic, span);
			var statements:Array<TypedStatement> = [];
			var isNull = new TypedExpression(TEqual(source, coerce(new TypedExpression(TNullLiteral, TNull, span), TDynamic, "null comparison")), TBool, span);
			statements.push(TIf(isNull, [
				TReturn(coerce(new TypedExpression(TNullLiteral, TNull, span), target, "null structure"), span)
			], [], span));
			var output:Array<compiler.types.TypedAst.TypedObjectField> = [];
			var result:TypedExpression;
			switch target {
				case TAnonymous(_, fields):
					for (field in fields) {
						var key = new TypedExpression(TStringLiteral(field.name), TString, span);
						if (!field.optional) {
							var present = new TypedExpression(TCall("Reflect.hasField", [source, key]), TBool, span);
							var message = new TypedExpression(TStringLiteral('Missing required field "${field.name}" in dynamic structure conversion'),
								TString, span);
							statements.push(TIf(new TypedExpression(TNot(present), TBool, span),
								[TThrow(coerce(message, TDynamic, "conversion error"), span)], [], span));
						}
						var fieldLocal = "$field:" + field.name;
						statements.push(TVar(fieldLocal, new TypedExpression(TCall("Reflect.field", [source, key]), TDynamic, span), span));
						var read = new TypedExpression(TLocal(fieldLocal), TDynamic, span);
						var matches = dynamicFieldMatches(read, field.type);
						if (matches != null) {
							var message = new TypedExpression(TStringLiteral('Invalid type for field "${field.name}" in dynamic structure conversion'),
								TString, span);
							statements.push(TIf(new TypedExpression(TNot(matches), TBool, span),
								[TThrow(coerce(message, TDynamic, "conversion error"), span)], [], span));
						}
						output.push({
							name: field.name,
							value: structuralCopyTarget(field.type) != null ? dynamicStructure(read,
								field.type) : coerce(read, field.type, 'dynamic field "${field.name}"')
						});
					}
					result = new TypedExpression(TObjectLiteral(name, output, false), target, span);
				case TArray(element):
					var matches = dynamicFieldMatches(source, target);
					if (matches == null)
						throw "Missing array conversion check";
					var message = new TypedExpression(TStringLiteral("Expected an array in dynamic structure conversion"), TString, span);
					statements.push(TIf(new TypedExpression(TNot(matches), TBool, span), [TThrow(coerce(message, TDynamic, "conversion error"), span)], [],
						span));
					var array = new TypedExpression(TLocal("items"), TArray(TDynamic), span);
					var copied = new TypedExpression(TLocal("copied"), target, span);
					statements.push(TVar("items", new TypedExpression(TCast(source), TArray(TDynamic), span), span));
					statements.push(TVar("copied", new TypedExpression(TArrayLiteral([]), target, span), span));
					var item = dynamicStructure(new TypedExpression(TLocal("item"), TDynamic, span), element);
					statements.push(TForIn("item", null, array, [TExpression(new TypedExpression(TArrayPush(copied, item), TInt, span), span)], span));
					result = copied;
				default:
					throw "Unsupported structural copy target";
			}
			statements.push(TReturn(result, span));
			session.closureConversion.addFunction({
				name: helper,
				origin: origin,
				originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
				owner: null,
				isStatic: true,
				isConstructor: false,
				arguments: [
					{
						name: "source",
						type: TDynamic
					}
				],
				result: target,
				statements: statements,
				cells: [],
				cellCaptures: [],
				span: span
			});
			session.dynamicStructureConversions.set(helper, false);
		}
		var converted = new TypedExpression(TCall(helper, [value]), target, value.span);
		return TypeRelations.equals(target, expected) ? converted : new TypedExpression(TCast(converted), expected, value.span);
	}

	/** Reject wrong primitive/callable kinds before backend casts, so malformed data throws a Haxe exception. */
	function dynamicFieldMatches(value:TypedExpression, type:CompilerType):Null<TypedExpression> {
		var span = value.span;
		function typeTest(target:CompilerType):TypedExpression
			return new TypedExpression(TCall("__std_is_of_type", [value, new TypedExpression(TClassRef(""), target, span)]), TBool, span);
		var matches:Null<TypedExpression> = switch type {
			case TDynamic, TAnonymous(_, _): null;
			case TNullable(element): dynamicFieldMatches(value, element);
			case TAbstract(_, _, representation): dynamicFieldMatches(value, representation);
			case TInt, TFloat: new TypedExpression(TOr(typeTest(TInt), typeTest(TFloat)), TBool, span);
			case TInt64, TBool, TString: typeTest(type);
			case TArray(_): typeTest(TArray(TDynamic));
			case TInstance(_, _, _): typeTest(type);
			case TFunction(_, _): new TypedExpression(TCall("Reflect.isFunction", [value]), TBool, span);
			default: null;
		};
		if (matches != null && (isNullable(type) || TypeRelations.isReference(type) && !session.relations.isValueClass(type))) {
			var nil = coerce(new TypedExpression(TNullLiteral, TNull, span), TDynamic, "nullable field");
			matches = new TypedExpression(TOr(new TypedExpression(TEqual(value, nil), TBool, span), matches), TBool, span);
		}
		return matches;
	}

	/** Reify an explicitly erased structural contract once at the boundary, never inside a loop. */
	function iterationAdapter(value:TypedExpression, expected:CompilerType):TypedExpression {
		var fields = switch expected {
			case TAnonymous(_, fields): fields;
			default: throw "Expected iteration contract";
		};
		var span = value.span, context = session.currentContext.name;
		var id = session.functionAdapterCounts.exists(context) ? session.functionAdapterCounts.get(context) : 0;
		session.functionAdapterCounts.set(context, id + 1);
		var localName = "$iteration-source:" + context + ":" + id;
		var local = new TypedExpression(TLocal(localName), value.type, span);
		var output:Array<compiler.types.TypedAst.TypedObjectField> = [];
		for (field in fields) {
			var functionName = "$iteration-adapter:" + context + ":" + id + ":" + field.name;
			var environment = functionName + ":env";
			var captures:Array<TypedCapture> = [
				{
					field: "source",
					bindingId: localName,
					type: value.type,
					storageType: value.type,
					source: CaptureExpression(local)
				}
			];
			var captured = new TypedExpression(TCaptured("source"), value.type, span, false, null, value.type);
			var result = switch field.type {
				case TFunction([], result): result;
				default: throw "Expected protocol method";
			};
			var call = IterationProtocol.call(session, captured, field.name);
			var converted = coerce(call, result, "iteration method result");
			session.closureConversion.addEnvironment(environment, captures);
			session.closureConversion.addFunction({
				name: functionName,
				origin: context,
				originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
				owner: environment,
				isStatic: false,
				isConstructor: false,
				arguments: [],
				result: result,
				statements: [TReturn(converted, span)],
				cells: [],
				cellCaptures: [],
				span: span
			});
			output.push({name: field.name, value: new TypedExpression(TLambda(functionName, environment, captures), field.type, span)});
		}
		new AnonymousTypeRegistry(session).register(expected);
		var name = switch expected {
			case TAnonymous(name, _): name;
			default: "";
		};
		return new TypedExpression(TBlockExpression([TVar(localName, ValueCopy.bind(session, value, value.type), span)],
			new TypedExpression(TObjectLiteral(name, output, false), expected, span)),
			expected, span);
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
		return value.type == TDynamic
			&& anonymousTarget(expected) != null ? dynamicStructure(value, expected) : functionAdapter(value, expected, span);

	/** A callable's argument/result ABI needs an adapter even when both values are references. */
	public static function functionSignaturesDiffer(actual:CompilerType, expected:CompilerType):Bool {
		var source = expectedFunctionType(actual),
			target = expectedFunctionType(expected);
		return source != null
			&& target != null
			&& !TypeRelations.equals(TFunction(source.arguments, source.result), TFunction(target.arguments, target.result));
	}

	function functionAdapter(value:TypedExpression, expected:CompilerType, span:SourceSpan):TypedExpression {
		var sourceSignature = expectedFunctionType(value.type),
			targetSignature = expectedFunctionType(expected);
		if (sourceSignature == null || targetSignature == null)
			return new TypedExpression(TCast(value), expected, span);
		if (isNullable(value.type) && functionSignaturesDiffer(value.type, expected)) {
			// Evaluate the callable once and retain null as null rather than creating
			// a non-null wrapper which would call a missing function later.
			var contextName = session.currentContext.name,
				adapterId = session.functionAdapterCounts.exists(contextName) ? session.functionAdapterCounts.get(contextName) : 0,
				localName = '$' + 'nullable-function-adapter:$contextName:$adapterId',
				local = new TypedExpression(TLocal(localName), value.type, span),
				sourceType = TFunction(sourceSignature.arguments, sourceSignature.result),
				nonNull = new TypedExpression(TCast(local), sourceType, span),
				adapted = functionAdapter(nonNull, expected, span),
				nullValue = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), value.type, span),
				condition = new TypedExpression(TEqual(local, nullValue), TBool, span),
				result = new TypedExpression(TConditional(condition,
					new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), expected, span), adapted),
					expected, span);
			return new TypedExpression(TBlockExpression([TVar(localName, value, span)], result), expected, span);
		}
		var sourceArguments = sourceSignature.arguments,
			sourceResult = sourceSignature.result,
			targetArguments = targetSignature.arguments,
			targetResult = targetSignature.result;
		if (sourceArguments.length != targetArguments.length || TypeRelations.equals(value.type, expected))
			return new TypedExpression(TCast(value), expected, span);
		var contextName = session.currentContext.name,
			adapterId = session.functionAdapterCounts.exists(contextName) ? session.functionAdapterCounts.get(contextName) : 0;
		session.functionAdapterCounts.set(contextName, adapterId + 1);
		var adapterName = '$' + 'function-adapter:$contextName:$adapterId', environmentName = '$' + 'function-adapter-env:$contextName:$adapterId',
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
			origin: contextName,
			originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
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
		if (functionSignaturesDiffer(value.type, target))
			return functionAdapter(value, target, span);
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
