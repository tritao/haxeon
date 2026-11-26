package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstAbstract;
import compiler.types.InlineConstantEvaluator;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedFunctionRole;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.HelperRequests.HelperRequest;

/** A raw-value enum's `rawValue`, `fromRaw()` and `toString()`, synthesized from its cases, never from runtime reflection. */
@:access(compiler.types.typing.BodyTyper)
class RawEnumGenerator {
	public static inline final PREFIX = "$raw-enum:";

	/** Whether `declaration` is a raw-value enum, `enum Name:Int { ... }`. */
	public static function conforms(session:TypingSession, declaration:AstAbstract):Bool
		return declaration.isRawEnum == true;

	public static function name(owner:String, method:String):String
		return PREFIX + owner + ":" + method;

	/** A raw-value enum's codes are of an Int or String raw type, compile-time constants, and unique. */
	public static function validate(session:TypingSession, typer:BodyTyper, declaration:AstAbstract):Void {
		if (!conforms(session, declaration))
			return;
		switch typer.lowerType(declaration.underlying, declaration.span) {
			case TInt, TString:
			default:
				BodyTyper.fail(DiagnosticCode.CONFORMANCE,
					'Enum "${declaration.name}": a raw value is an Int or a String',
					declaration.span);
		}
		// rawValue and fromRaw are the code and its inverse; a member of either name would break the round trip.
		for (method in declaration.methods)
			if (method.name == "rawValue" || method.name == "fromRaw")
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
					'Enum "${declaration.name}" synthesizes ${method.name}; it cannot declare one', method.span);
		for (field in declaration.fields)
			if (field.name == "rawValue" || field.name == "fromRaw")
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
					'Enum "${declaration.name}" synthesizes ${field.name}; it cannot declare one', field.span);
		var seen:Map<String, String> = [];
		for (value in declaration.values) {
			if (value.name == "rawValue" || value.name == "fromRaw" || value.name == "toString")
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
					'Enum case ${declaration.name}.${value.name} has the name of a synthesized member', value.span);
			var constant = InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration, value));
			if (constant == null)
				BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
					'Enum case ${declaration.name}.${value.name} needs a compile-time constant raw value', value.span);
			// A code names one case, so fromRaw can return it.
			var key = switch constant.expression {
				case TIntLiteral(raw): "int:" + raw;
				case TStringLiteral(raw): "string:" + raw;
				default: value.name;
			};
			var other = seen.get(key);
			if (other != null)
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
					'Enum case ${declaration.name}.${value.name} has the raw value of ${declaration.name}.$other',
					value.span);
			seen.set(key, value.name);
		}
	}

	public static function request(session:TypingSession, owner:String, method:String, span:SourceSpan):String {
		if (method != "rawValue" && method != "fromRaw" && method != "toString")
			throw new InternalError('Unknown synthesized raw member "$method"');
		var helper = name(owner, method);
		session.requestHelper(RawEnumHelper(helper, {
			owner: owner,
			method: method,
			origin: session.generatedFunctionOrigin(),
			span: span
		}));
		return helper;
	}

	/**
	 * `toString` names the value as a Haxe enum constructor prints (`Button`); the first of several names for one raw value
	 * wins. A raw value outside the declared set, such as a newer native code, prints as `Owner(raw)`.
	 */
	static function nameStatements(typer:BodyTyper, declaration:AstAbstract, raw:CompilerType,
			rawValue:TypedExpression,
			span:SourceSpan):Array<TypedStatement> {
		function text(value:String):TypedExpression
			return new TypedExpression(TStringLiteral(value), TString, span);
		var statements:Array<TypedStatement> = [], seen:Map<String, Bool> = [];
		for (value in declaration.values) {
			var constant = InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration, value));
			if (constant == null)
				throw new InternalError("Nonconstant raw value after conformance validation");
			var key = Std.string(constant.expression);
			if (seen.exists(key))
				continue;
			seen.set(key, true);
			statements.push(TIf(new TypedExpression(TEqual(rawValue, constant), TBool, span),
				[TReturn(text(value.name), span)], [], span));
		}
		var shown = switch raw {
			case TString: rawValue;
			default: new TypedExpression(TCall("__std_string",
				[new TypedExpression(TToDynamic(rawValue), TDynamic, span)]), TString, span);
		};
		var owner = compiler.core.QualifiedName.last(declaration.name);
		statements.push(TReturn(new TypedExpression(TAdd(text(owner + "("),
			new TypedExpression(TAdd(shown, text(")")), TString, span)), TString,
			span), span));
		return statements;
	}

	/** Drain only newly requested members when dependency completion makes another pass. */
	public static function generate(session:TypingSession, typer:BodyTyper,
			generated:Map<String, TypedFunction>):Array<TypedFunction> {
		var pending = [
			for (name in session.programOutput.requests.rawEnums.keys())
				if (!generated.exists(name)) name
		];
		pending.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		for (helper in pending) {
			var fn = session.typeHelper(helper, () -> member(session, typer, helper));
			generated.set(helper, fn);
			result.push(fn);
		}
		return result;
	}

	/** The member `helper` a raw-value enum was asked for. */
	static function member(session:TypingSession, typer:BodyTyper, helper:String):TypedFunction {
		var request:HelperRequests.MemberHelperRequest = session.programOutput.requests.rawEnums.get(helper),
			declaration = session.enumAbstractDecls.get(request.owner);
		if (declaration == null || !conforms(session, declaration))
			throw new InternalError('Missing raw-value enum "${request.owner}"');
		var raw = typer.lowerType(declaration.underlying, declaration.span),
			nominal:CompilerType = TAbstract(declaration.name, [], raw),
			span = declaration.span,
			inputType = request.method == "fromRaw" ? raw : nominal,
			input = new TypedExpression(TLocal("value"), inputType, span),
			outputType:CompilerType = switch request.method {
				case "rawValue": raw;
				case "toString": TString;
				default: TNullable(nominal);
			},
				statements:Array<TypedStatement> = [];
		if (request.method == "rawValue")
			statements.push(TReturn(new TypedExpression(TAbiCast(input), raw, span), span));
		else if (request.method == "toString")
			statements = nameStatements(typer, declaration, raw,
				new TypedExpression(TAbiCast(input), raw, span),
				span);
		else {
			var present =
				new TypedExpression(TNullableWrap(new TypedExpression(TAbiCast(input), nominal, span)),
				outputType, span),
				missing =
					TReturn(new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
					outputType, span), span),
				cases:Array<compiler.types.TypedAst.TypedSwitchCase> = [],
				seen:Map<Int, Bool> = [];
			for (value in declaration.values) {
				var constant = InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration,
					value));
				if (constant == null)
					throw new InternalError("Nonconstant raw value after conformance validation");
				switch raw {
					case TInt:
						var code = switch constant.expression {
							case TIntLiteral(value): value;
							default: throw new InternalError("Noninteger raw constant");
						};
						if (seen.exists(code))
							continue;
						seen.set(code, true);
						cases.push({
							arms: [{
								value: constant,
								subjectBinding: null,
								arrayPattern: null,
								isCatchAll: false,
								guard: null,
								enumName: null,
								constructorIndex: -1,
								bindings: [],
								predicates: [],
								span: span
							}],
							statements: [TReturn(present, span)]
						});
					default:
						statements.push(TIf(new TypedExpression(TEqual(input, constant), TBool, span),
							[TReturn(present, span)], [], span));
				}
			}
			switch raw {
				case TInt:
					statements.push(TSwitch(input, cases, [missing], true, span));
				default:
					statements.push(missing);
			}
		}

		var fn:TypedFunction = {
			name: helper,
			role: ProviderFunction(nominal, compiler.core.Provides.ProviderOperations
				.detailed(compiler.core.Provides.ProviderOperation.RawEnum, request.method)),
			origin: request.origin,
			originKind: Helper,
			owner: null,
			isStatic: true,
			isConstructor: false,
			// A name lookup has a branch per value: keep it one call, not a copy at every string conversion.
			isInline: request.method != "toString",
			arguments: [{name: "value", type: inputType}],
			result: outputType,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: span
		};
		return fn;
	}
}
