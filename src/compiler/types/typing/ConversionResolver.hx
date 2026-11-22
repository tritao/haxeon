package compiler.types.typing;

import compiler.core.InternalError;
import compiler.types.Monomorphs;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.IterationProtocol;
import compiler.types.TypedAst.TypedCapture;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.NullSafety.NullSafetyUse;

/** Applies the conversion plan selected by the compilation's type relations. */
class ConversionResolver {
	final session:TypingSession;

	/** Calls the abstract instance method named on a value of the abstract: a `@:to` function's call (`CallResolver`). */
	final abstractMethodCall:(receiver:TypedExpression, method:String, span:SourceSpan) -> TypedExpression;

	public function new(session:TypingSession,
			abstractMethodCall:(receiver:TypedExpression, method:String, span:SourceSpan) -> TypedExpression) {
		this.session = session;
		this.abstractMethodCall = abstractMethodCall;
	}

	/** A Never value takes the expected type; a block's value is its result, so the result takes it too. */
	static function neverAs(value:TypedExpression, expected:CompilerType):TypedExpression
		return switch value.expression {
			case TBlockExpression(statements, result) if ((switch (result.type) {
				case TNever: true;
				default: false;
			})): new TypedExpression(TBlockExpression(statements, neverAs(result, expected)), expected, value.span);
			default:
				new TypedExpression(value.expression, expected, value.span);
		};

	/**
	 * `value` where Haxe needs a plain Int, Float, Bool or Int64 (an arithmetic, bitwise or ordering operand, a negation, a
	 * condition): a nullable of one reads as that type, null giving its default, so `total += stack.pop()` and `if (flag)` work
	 * on nullables as in Haxe. Anything else is returned as it is. Equality keeps the nullable, so `x == null` still sees null.
	 */
	public static function plainValue(value:TypedExpression, bodyTyper:BodyTyping,
			?use:NullSafetyUse):TypedExpression
		return switch value.type {
			case TNullable(element) if (TypeRelations.hasNullDefault(element)): bodyTyper.coerce(value, element,
				"operand",
				"E1010", use);
			default: value;
		};

	/** `value ?? default`: a nullable scalar read as its element type, null giving the type's Haxe default. Evaluates `value` once. */
	function nullableWithDefault(value:TypedExpression, expected:CompilerType, context:String, position:Int,
			code:String):TypedExpression {
		warnNullDefault(value, expected);
		return readWithDefault(value, expected, context, position, code);
	}

	/** `value`, a nullable number, read as `expected`, with null read as the type's default (0, 0.0, false). */
	function readWithDefault(value:TypedExpression, expected:CompilerType, context:String, position:Int,
			code:String):TypedExpression {
		var element = switch value.type {
			case TNullable(inner): inner;
			default: value.type;
		};
		var span = value.span,
			id = '$' + 'nullable-default-value:${session.currentContext.nullableDefaultTemporary++}',
			local = new TypedExpression(TLocal(id), value.type, span),
			nilValue = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), value.type,
				span),
			isNull = new TypedExpression(TEqual(local, nilValue), TBool, span),
			present = convert(new TypedExpression(TCast(local), element, span), expected, context, position, code),
			fallback = switch expected {
				case TFloat: new TypedExpression(TFloatLiteral(0.0), TFloat, span);
				case TBool: new TypedExpression(TBoolLiteral(false), TBool, span);
				case TInt64: new TypedExpression(TIntToInt64(new TypedExpression(TIntLiteral(0), TInt, span)), TInt64,
					span);
				default: new TypedExpression(TIntLiteral(0), TInt, span);
			};
		return new TypedExpression(TBlockExpression([TVar(id, value, span)],
			new TypedExpression(TConditional(isNull, fallback, present), expected, span)),
			expected, span);
	}

	/**
	 * W1001: a nullable read as its plain type turns null into a default silently, which hides a missing map entry or an
	 * empty pop. The fix writes the default out with `??`, which says it was meant and reads the same.
	 */
	function warnNullDefault(value:TypedExpression, expected:CompilerType):Void {
		var span = value.span,
			defaultText = switch expected {
				case TFloat: "0.0";
				case TBool: "false";
				default: "0";
			};
		var fixes:Array<DiagnosticFix> = if (span.end > span.start)[
			{
				id: "explicit-null-default",
				title: 'Write the default: ?? $defaultText',
				edits: [{span: span, replacement: '(${span.file.slice(span.start, span.end)} ?? $defaultText)'}]
			}
		] else [];
		session.warn(new Diagnostic("W1001",
			'${SemanticSignature.display(value.type)} is read as ${SemanticSignature.display(expected)}, so null becomes $defaultText; write "?? $defaultText" if that is meant',
			span, Warning, fixes));
	}

	/**
	 * `value` as an `expected`, `context` naming it in a mismatch. `use` is where the value meets the type, for the null-safety
	 * checker (`NullSafety.checkConversion`), which checks after the conversion has filled the type variables on either side.
	 */
	public function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009",
			?use:NullSafetyUse):TypedExpression {
		var converted = convert(value, expected, context, 0, code);
		if (use != null)
			session.nullSafety.checkConversion(value, expected, use);
		return converted;
	}

	/**
	 * `value` as argument `position` (from 1) of a call to `callee`. A call coerces every argument, and the message's
	 * `argument N to "callee"` is spelled only when one does not convert.
	 */
	public function coerceArgument(value:TypedExpression, expected:CompilerType, callee:String, position:Int,
			?use:NullSafetyUse):TypedExpression {
		var converted = convert(value, expected, callee, position, "E1009");
		session.nullSafety.checkConversion(value, expected, use == null ? Argument(callee, position) : use);
		return converted;
	}

	/** What a mismatch names: `context`, or, with `position` set, that argument of a call to `context`. */
	static function subject(context:String, position:Int):String
		return position == 0 ? context : 'argument $position to "$context"';

	function convert(value:TypedExpression, expected:CompilerType, context:String, position:Int,
			code:String):TypedExpression {
		// Where a value meets the type it must have, an empty type variable on either side takes the other's type.
		if (session.monomorphs.active()) {
			Monomorphs.unify(value.type, expected);
			expected = Monomorphs.resolve(expected);
			// A value that iterates meets an iteration structure element by element: an Array<String> fills `Iterable<?>`.
			var protocol = IterationProtocol.name(expected);
			if (protocol != null) {
				var actualElement = IterationProtocol.element(session.declarations, value.type, protocol == "Iterable"),
					expectedElement = IterationProtocol.element(session.declarations, expected, protocol == "Iterable");
				if (actualElement != null && expectedElement != null) {
					Monomorphs.unify(actualElement, expectedElement);
					expected = Monomorphs.resolve(expected);
				}
			}
			if (Monomorphs.contains(value.type))
				value = new TypedExpression(value.expression, Monomorphs.resolve(value.type), value.span,
					value.stableFlowValue,
					value.mapKeySource, value.storageType, value.semanticReference);
		}
		// An object literal's open structure meeting a structure gains the optional fields it lacks, in place (MonomorphFrames).
		session.monomorphs.gain(value.type, expected);
		if ((switch (value.type) {
			case TNever: true;
			default: false;
		}))
			return neverAs(value, expected);
		// Where a type parameter is on either side, what the conversion is physically depends on what the parameter stands for:
		// it is recorded, and the elaboration pass makes it for each representation (`GenericElaboration`).
		if (mentionsTypeParameter(value.type, expected) && !isNullIntoNullable(value.type, expected)
			&& !session.relations.conversion(value.type, expected).match(Incompatible))
			return new TypedExpression(TParameterConversion(value, Coerce), expected, value.span,
				value.stableFlowValue);
		if ((switch (value.type) {
			case TDynamic: true;
			default: false;
		}) && anonymousTarget(expected) != null)
			return dynamicStructure(value, expected);
		if (IterationProtocol.name(expected) != null && (switch (value.type) {
			case TNull: false;
			default: true;
		}) && !TypeRelations.equals(value.type, expected)) {
			if (!session.relations.isAssignable(value.type, expected))
				fail(code,
					'Type mismatch for ${subject(context, position)}: iteration requires compatible iterator(), hasNext():Bool and next() methods',
					value.span);
			return iterationAdapter(value, expected);
		}
		// An optional enum needs an adapter only when present. Bind its expression once before the presence check.
		switch value.type {
			case TNullable(TInstance(NominalKind.Enum, enumName, enumArguments)):
				var element:CompilerType = TInstance(NominalKind.Enum, enumName, enumArguments);
				var interfaceType = switch expected {
					case TInstance(NominalKind.Interface, _, _): expected;
					case TNullable(TInstance(NominalKind.Interface, interfaceName, interfaceArguments)):
						TInstance(NominalKind.Interface, interfaceName, interfaceArguments);
					default: null;
				};
				if (interfaceType != null && session.relations.satisfiesConstraint(element, interfaceType)) {
					var span = value.span,
						id = '$' + 'enum-interface-value:${session.currentContext.enumInterfaceTemporary++}',
						local = new TypedExpression(TLocal(id), value.type, span),
						nilValue = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
							value.type, span),
						isNull = new TypedExpression(TEqual(local, nilValue), TBool, span),
						present = convert(new TypedExpression(TCast(local), element, span), interfaceType, context,
							position,
							code),
						nilResult = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
							expected, span),
						result = (switch expected {
							case TNullable(_): new TypedExpression(TNullableWrap(present), expected, span);
							default: present;
						});
					return new TypedExpression(TBlockExpression([TVar(id, value, span)],
						new TypedExpression(TConditional(isNull, nilResult, result), expected, span)), expected, span);
				}
			default:
		}
		switch expected {
			// A Dynamic converts to a nullable by one cast, below. Converting it to the element first would turn a null into a zero.
			case TNullable(element) if ((switch (value.type) {
				case TNull: false;
				default: true;
			}) && (switch (value.type) {
				case TDynamic: false;
				default: true;
			}) && !isNullable(value.type)): var converted = convert(value, element, context, position, code);
			return new TypedExpression(TNullableWrap(converted), expected, value.span);
			default:
		}
		// Preserve null while converting a present nullable element through the abstract's @:from.
		switch [value.type, expected] {
			case [TNullable(element), TNullable(target)] if ((switch (target) {
				case TAbstract(_, _, _): true;
				default: false;
			}) && (switch (session.relations.conversion(element, target)) {
				case AbstractCast: true;
				default: false;
			})): var span = value.span,
				id = '$' + 'nullable-abstract-value:${session.currentContext.nullableAbstractTemporary++}',
				local = new TypedExpression(TLocal(id), value.type, span),
				nilValue = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
				value.type, span),
				isNull = new TypedExpression(TEqual(local, nilValue), TBool, span),
				present = convert(new TypedExpression(TCast(local), element, span), target, context, position, code),
				nilResult = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), expected,
				span),
				result = new TypedExpression(TNullableWrap(present), expected, span);
			return new TypedExpression(TBlockExpression([TVar(id, value, span)],
				new TypedExpression(TConditional(isNull, nilResult, result), expected, span)), expected, span);
			default:
		}
		// A nullable converts through the abstract's @:from function for its element, so unwrap it first, as Haxe does.
		switch [value.type, expected] {
			case [TNullable(element),
				TAbstract(_, _, _)] if ((switch (session.relations.conversion(element, expected)) {
					case AbstractCast: true;
					default: false;
				})): return convert(new TypedExpression(TCast(value), element, value.span), expected, context, position,
					code);
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
				adaptFunction(value, expected, value.span);
			case AbstractCast:
				abstractCast(value, expected, context, position, code);
			case ToDynamic:
				// A dynamic box stores a pointer, not an inline copy. Own a value-class payload before boxing it.
				var owned = ValueCopy.bind(session, value, value.type), enumType = EnumDynamicBox.enumType(value.type);
				if (enumType != null) EnumDynamicBox.box(session, owned, enumType, value.span);
				else switch value.type {
					case TArray(element):
						var arrayEnum = EnumDynamicBox.enumType(element);
						if (arrayEnum == null) new TypedExpression(TToDynamic(owned), expected, value.span);
						else {
							var view = new TypedExpression(TCast(owned), TArray(TDynamic), value.span);
							new TypedExpression(TToDynamic(EnumDynamicBox.view(session, view, arrayEnum, value.span)),
								expected, value.span);
						}
					default: new TypedExpression(TToDynamic(owned), expected, value.span);
				};
			case ToInterface(name):
				// The interface value owns a boxed copy of a struct, not the source place.
				var converted = switch value.type {
					case TInstance(NominalKind.Enum, _, _):
						var adapter = EnumInterfaceAdapter.request(session, value.type, expected, value.span);
						new TypedExpression(TNew(adapter, [value], true), TInstance(NominalKind.Class, adapter, []),
							value.span);
					default: ValueCopy.bind(session, value, value.type);
				};
				new TypedExpression(TToInterface(converted, name), expected, value.span);
			case WrapNullable:
				new TypedExpression(TNullableWrap(value), expected, value.span);
			case UnwrapNullable:
				new TypedExpression(TCast(value), expected, value.span);
			case UnwrapNullableDefault:
				nullableWithDefault(value, expected, context, position, code);
			case Incompatible:
				var closed = closedLiteralMismatch(value.type, expected);
				fail(code,
					closed
					?? 'Type mismatch for ${subject(context, position)}: expected ${SemanticSignature.display(expected)}, got ${SemanticSignature.display(value.type)}',
					value.span);
				value;
		};
	}

	/**
	 * Why a structure that comes from an object literal of another unit does not convert to `expected`, when gaining optional fields
	 * would have made it convert: the literal's structure closed with the unit of the unannotated declaration that returned or held
	 * it, so it no longer gains fields, where Haxe keeps it open (docs/design/STRUCTURE_VALUES.md, decision 3). Null otherwise.
	 */
	function closedLiteralMismatch(actual:CompilerType, expected:CompilerType):Null<String> {
		var actualFields = ExpressionTyper.anonymousFields(nonNullable(actual)),
			expectedFields = ExpressionTyper.anonymousFields(nonNullable(expected));
		if (actualFields == null || expectedFields == null)
			return null;
		var origin = session.monomorphs.literalOrigin(actualFields);
		if (origin == null)
			return null;
		var missing:Array<String> = [];
		for (field in expectedFields) {
			var own = ExpressionTyper.anonymousField(actualFields, field.name);
			if (own == null) {
				if (!field.optional)
					return null;
				missing.push(field.name);
			} else if (own.optional != field.optional || !TypeRelations.equals(own.type, field.type))
				return null;
		}
		if (missing.length == 0 || actualFields.length + missing.length != expectedFields.length)
			return null;
		var spelled =
			'{${[for (field in actualFields) (field.optional ? "?" : "") + field.name + " : " + SemanticSignature.display(field.type)].join(", ")}}',
			annotate = origin.isField
				? 'the type of field "${origin.declaration}"' : 'the result of "${origin.declaration}"';
		return '$spelled has no field ${missing[0]}; the structure comes from a literal in "${origin.declaration}", which closed its type; annotate $annotate';
	}

	/** A null literal made a nullable's null, which is the same for every representation. */
	static function isNullIntoNullable(actual:CompilerType, expected:CompilerType):Bool
		return actual.match(TNull) && expected.match(TNullable(_));

	static function mentionsTypeParameter(actual:CompilerType, expected:CompilerType):Bool
		return TypeRepresentation.mentionsTypeParameter(actual) || TypeRepresentation.mentionsTypeParameter(expected);

	static function nonNullable(type:CompilerType):CompilerType
		return switch type {
			case TNullable(element): nonNullable(element);
			default: type;
		};

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
			throw new InternalError("Expected anonymous conversion target");
		var name = switch target {
			case TAnonymous(name, _): name;
			default: compiler.semantic.SemanticSignature.type(target);
		};
		var origin = session.currentContext.name, span = value.span;
		var helper = compiler.core.GlobalNames.of("$dynamic-structure:" + origin + ":" + name);
		if (session.dynamicStructureConversions.get(helper) == true)
			fail("E1016",
				"Recursive Dynamic to anonymous structure conversion is not supported; convert the recursive fields explicitly",
				span);
		if (!session.dynamicStructureConversions.exists(helper)) {
			// Reject recursive copies: cyclic Dynamic input cannot be copied without an identity table.
			session.dynamicStructureConversions.set(helper, true);
			session.runtimeDependencyTracker.record(origin, "Reflect");
			new AnonymousTypeRegistry(session).register(target);
			var source = new TypedExpression(TLocal("source"), TDynamic, span);
			var statements:Array<TypedStatement> = [];
			var isNull = new TypedExpression(TEqual(source,
				coerce(new TypedExpression(TNullLiteral, TNull, span), TDynamic, "null comparison")), TBool, span);
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
							var message =
								new TypedExpression(TStringLiteral('Missing required field "${field.name}" in dynamic structure conversion'),
								TString, span);
							statements.push(TIf(new TypedExpression(TNot(present), TBool, span),
								[TThrow(coerce(message, TDynamic, "conversion error"), span)], [], span));
						}
						var fieldLocal = "$field:" + field.name;
						statements.push(TVar(fieldLocal,
							new TypedExpression(TCall("Reflect.field", [source, key]), TDynamic, span), span));
						var read = new TypedExpression(TLocal(fieldLocal), TDynamic, span);
						var matches = dynamicFieldMatches(read, field.type);
						if (matches != null) {
							var message =
								new TypedExpression(TStringLiteral('Invalid type for field "${field.name}" in dynamic structure conversion'),
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
						throw new InternalError("Missing array conversion check");
					var message =
						new TypedExpression(TStringLiteral("Expected an array in dynamic structure conversion"),
						TString, span);
					statements.push(TIf(new TypedExpression(TNot(matches), TBool, span),
						[TThrow(coerce(message, TDynamic, "conversion error"), span)], [],
						span));
					var array = new TypedExpression(TLocal("items"), TArray(TDynamic), span);
					var copied = new TypedExpression(TLocal("copied"), target, span);
					statements.push(TVar("items", new TypedExpression(TCast(source), TArray(TDynamic), span), span));
					statements.push(TVar("copied", new TypedExpression(TArrayLiteral([]), target, span), span));
					var item = dynamicStructure(new TypedExpression(TLocal("item"), TDynamic, span), element);
					statements.push(TForIn("item", null, array,
						[TExpression(new TypedExpression(TArrayPush(copied, item), TInt, span), span)], span));
					result = copied;
				default:
					throw new InternalError("Unsupported structural copy target");
			}
			statements.push(TReturn(result, span));
			// One helper per converting function and target: the origin details the operation, so two functions that convert to
			// the same structure serve two provider rows, not one row twice (`IrProviders.check`).
			var operation = compiler.core.Provides.ProviderOperations
				.detailed(compiler.core.Provides.ProviderOperation.DynamicStructure,
				origin);
			session.closureConversion.addFunction({
				name: helper, role: ProviderFunction(target, operation),
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
		return TypeRelations.equals(target, expected) ? converted : new TypedExpression(TCast(converted), expected,
			value.span);
	}

	/** Reject wrong primitive/callable kinds before backend casts, so malformed data throws a Haxe exception. */
	function dynamicFieldMatches(value:TypedExpression, type:CompilerType):Null<TypedExpression> {
		var span = value.span;
		function typeTest(target:CompilerType):TypedExpression
			return new TypedExpression(TCall("__std_is_of_type", [
				value,
				new TypedExpression(TClassRef(""), target, span)
			]), TBool, span);
		var matches:Null<TypedExpression> = switch type {
			case TDynamic, TAnonymous(_, _): null;
			case TNullable(element): dynamicFieldMatches(value, element);
			case TAbstract(_, _, representation): dynamicFieldMatches(value, representation);
			case TInt, TFloat: new TypedExpression(TOr(typeTest(TInt), typeTest(TFloat)), TBool, span);
			case TInt64, TBool, TString: typeTest(type);
			case TArray(_): typeTest(TArray(TDynamic));
			case TInstance(_, _, _): typeTest(type);
			case TFunction(_, _, _): new TypedExpression(TCall("Reflect.isFunction", [value]), TBool, span);
			default: null;
		};
		if (matches != null
			&& (isNullable(type) || TypeRelations.isReference(type) && !session.relations.isValueClass(type))) {
			var nil = coerce(new TypedExpression(TNullLiteral, TNull, span), TDynamic, "nullable field");
			matches = new TypedExpression(TOr(new TypedExpression(TEqual(value, nil), TBool, span), matches), TBool,
				span);
		}
		return matches;
	}

	/** Reify an explicitly erased structural contract once at the boundary, never inside a loop. */
	function iterationAdapter(value:TypedExpression, expected:CompilerType):TypedExpression {
		var fields = switch expected {
			case TAnonymous(_, fields): fields;
			default: throw new InternalError("Expected iteration contract");
		};
		var span = value.span, context = session.currentContext.name;
		var id = session.counters.nextFunctionAdapter(context);
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
				case TFunction([], result, _): result;
				default: throw new InternalError("Expected protocol method");
			};
			var call = IterationProtocol.call(session, captured, field.name);
			var converted = coerce(call, result, "iteration method result");
			session.closureConversion.addEnvironment(environment, captures);
			session.closureConversion.addFunction({
				name: functionName, role: IterationFunction,
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
			output.push({
				name: field.name,
				value: new TypedExpression(TLambda(functionName, environment, captures), field.type, span)
			});
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

	/** `value` as an `expected` by an abstract's implicit conversion: the route `AbstractConversionGraph.route` finds. */
	function abstractCast(value:TypedExpression, expected:CompilerType, context:String, position:Int,
			code:String):TypedExpression {
		var route = session.declarations.conversions.route(value.type, expected);
		return switch route {
			case FromFunction(name, argument):
				new TypedExpression(TCall(name, [convert(value, argument, context, position, code)]), expected,
					value.span);
			// A value of the very type the abstract converts from or to is the abstract's as it is.
			case FromType(declared):
				var converted = TypeRelations.equals(value.type, declared) ? value : convert(value, declared, context,
					position,
					code);
				session.representation.boundaryCast(converted, expected);
			case ToFunction(method, _):
				var call = abstractMethodCall(value, method, value.span);
				convert(call, expected, context, position, code);
			case ToType(declared):
				var converted = session.representation.boundaryCast(value, declared);
				TypeRelations.equals(declared, expected) ? converted : convert(converted, expected, context, position,
					code);
			case null:
				throw new InternalError("An abstract cast has no conversion route");
		};
	}

	public function adaptFunction(value:TypedExpression, expected:CompilerType, span:SourceSpan):TypedExpression {
		var converted = (switch (value.type) {
			case TDynamic: true;
			default: false;
		})
			&& anonymousTarget(expected) != null ? dynamicStructure(value, expected) : functionAdapter(value, expected,
			span);
		return switch [value.type, expected] {
			case [TArray(element), TArray(TDynamic)]:
				var enumType = EnumDynamicBox.enumType(element);
				enumType == null ? converted : EnumDynamicBox.view(session, converted, enumType, span);
			default: converted;
		};
	}

	/** A callable's argument/result ABI needs an adapter even when both values are references. */
	public static function functionSignaturesDiffer(actual:CompilerType, expected:CompilerType):Bool {
		var source = expectedFunctionType(actual),
			target = expectedFunctionType(expected);
		return source != null
			&& target != null
			&& !TypeRelations.equals(TFunction(source.arguments, source.result, []),
			TFunction(target.arguments, target.result, []));
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
				adapterId = session.counters.peekFunctionAdapter(contextName),
				localName = '$' + 'nullable-function-adapter:$contextName:$adapterId',
				local = new TypedExpression(TLocal(localName), value.type, span),
				sourceType = TFunction(sourceSignature.arguments, sourceSignature.result, []),
				nonNull = new TypedExpression(TCast(local), sourceType, span),
				adapted = functionAdapter(nonNull, expected, span),
				nullValue = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
					value.type, span),
				condition = new TypedExpression(TEqual(local, nullValue), TBool, span),
				result = new TypedExpression(TConditional(condition,
					new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), expected, span),
					adapted),
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
			adapterId = session.counters.nextFunctionAdapter(contextName);
		var adapterName = '$' + 'function-adapter:$contextName:$adapterId',
			environmentName = '$' + 'function-adapter-env:$contextName:$adapterId',
			captureName = '__adapted_callable',
			arguments = [for (index in 0...targetArguments.length)
				{
					name:'$' + 'adapter_arg_$index',
						type:targetArguments[index]
				}], captures:Array<TypedCapture> = [
					{
						field: captureName,
						bindingId: captureName,
						type: value.type,
						storageType: value.type,
						source: CaptureExpression(value)
					}
				], callable = new TypedExpression(TCaptured(captureName), value.type, span, false, null, value.type),
					callArguments = [
						for (index in 0...arguments.length)
							adaptFunctionValue(new TypedExpression(TLocal(arguments[index].name), arguments[index].type,
							span), sourceArguments[index], span)
					], call = new TypedExpression(TClosureCall(callable, callArguments), sourceResult, span),
					statements:Array<TypedStatement> = [];
		if ((switch (targetResult) {
			case TVoid: true;
			default: false;
		})) {
			statements.push(TExpression(call, span));
			statements.push(TReturnVoid(span));
		} else if ((switch (sourceResult) {
			case TVoid: false;
			default: true;
		}))
			statements.push(TReturn(adaptFunctionValue(call, targetResult, span), span));
		else
			return new TypedExpression(TCast(value), expected, span);
		session.closureConversion.addEnvironment(environmentName, captures);
		session.closureConversion.addFunction({
			name: adapterName, role: OtherFunction,
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
		// A null passed to or returned by the adapted function reads as the number's default, as on Haxe's HashLink target,
		// without W1001: no expression here takes the `??` it suggests.
		if (session.relations.conversion(value.type, target).match(UnwrapNullableDefault))
			return readWithDefault(value, target, "function value", 0, "E1002");
		if ((switch (value.type) {
			case TInt: true;
			default: false;
		}) && (switch (target) {
			case TFloat: true;
			default: false;
		}))
			return new TypedExpression(TIntToFloat(value), TFloat, span);
		if ((switch (value.type) {
			case TInt: true;
			default: false;
		}) && (switch (target) {
			case TInt64: true;
			default: false;
		}))
			return new TypedExpression(TIntToInt64(value), TInt64, span);
		if ((switch (value.type) {
			case TFloat: true;
			default: false;
		}) && (switch (target) {
			case TInt: true;
			default: false;
		}))
			return new TypedExpression(TFloatToInt(value), TInt, span);
		return new TypedExpression(TCast(value), target, span);
	}

	static function expectedFunctionType(type:Null<CompilerType>):Null<{
		arguments:Array<CompilerType>,
		result:CompilerType
	}> {
		if (type == null)
			return null;
		return switch type {
			case TFunction(arguments, result, _): {arguments: arguments, result: result};
			case TNullable(inner): expectedFunctionType(inner);
			default: null;
		};
	}

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
