package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.InlineConstantEvaluator;

/** Declared raw-value capabilities are synthesized from the current constants, never from runtime reflection. */
@:access(compiler.types.typing.BodyTyper)
class RawRepresentableGenerator {
	public static inline final PREFIX = "$raw-representable:";

	public static function conforms(session:TypingSession, declaration:AstEnumAbstract):Bool
		return DeclaredConformance.has(session, TAbstract(declaration.name, [], session.declarations.resolve(declaration.underlying, declaration.span)),
			"RawRepresentable");

	public static function name(owner:String, method:String):String
		return PREFIX + owner + ":" + method;

	public static function validate(session:TypingSession, typer:BodyTyper, declaration:AstEnumAbstract):Void {
		if (!conforms(session, declaration))
			return;
		var raw = typer.lowerType(declaration.underlying);
		switch raw {
			case TInt, TString:
			default:
				BodyTyper.fail("E1025", "RawRepresentable requires an Int or String enum abstract", declaration.span);
		}
		if (declaration.fromTypes.length != 0 || declaration.toTypes.length != 0)
			BodyTyper.fail("E1025", "RawRepresentable enum abstracts cannot declare implicit from/to conversions", declaration.span);
		for (value in declaration.values) {
			if (value.name == "rawValue" || value.name == "fromRaw")
				BodyTyper.fail("E1000", 'Constant "${declaration.name}.${value.name}" conflicts with a synthesized RawRepresentable member', value.span);
			if (InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration, value)) == null)
				BodyTyper.fail("E1002", "RawRepresentable requires compile-time constant raw values", value.span);
		}
	}

	public static function request(session:TypingSession, owner:String, method:String, span:SourceSpan):String {
		if (method != "rawValue" && method != "fromRaw")
			throw 'Unknown synthesized raw member "$method"';
		var helper = name(owner, method);
		if (!session.rawRepresentableRequests.exists(helper))
			session.rawRepresentableRequests.set(helper, {
				owner: owner,
				method: method,
				origin: session.generatedFunctionOrigin(),
				span: span
			});
		return helper;
	}

	/** Drain only newly requested members when dependency completion makes another pass. */
	public static function generate(session:TypingSession, typer:BodyTyper, generated:Map<String, TypedFunction>):Array<TypedFunction> {
		var pending = [
			for (name in session.rawRepresentableRequests.keys())
				if (!generated.exists(name)) name
		];
		pending.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		for (helper in pending) {
			var request = session.rawRepresentableRequests.get(helper),
				declaration = session.enumAbstractDecls.get(request.owner);
			if (declaration == null || !conforms(session, declaration))
				throw 'Missing RawRepresentable declaration "${request.owner}"';
			var raw = typer.lowerType(declaration.underlying),
				nominal:CompilerType = TAbstract(declaration.name, [], raw),
				span = declaration.span,
				inputType = request.method == "rawValue" ? nominal : raw,
				input = new TypedExpression(TLocal("value"), inputType, span),
				outputType:CompilerType = request.method == "rawValue" ? raw : TNullable(nominal),
				statements:Array<TypedStatement> = [];
			if (request.method == "rawValue")
				statements.push(TReturn(new TypedExpression(TAbiCast(input), raw, span), span));
			else {
				var present = new TypedExpression(TNullableWrap(new TypedExpression(TAbiCast(input), nominal, span)), outputType, span),
					missing = TReturn(new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), outputType, span), span),
					cases:Array<compiler.types.TypedAst.TypedSwitchCase> = [],
					seen:Map<Int, Bool> = [];
				for (value in declaration.values) {
					var constant = InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration, value));
					if (constant == null)
						throw "Nonconstant raw value after conformance validation";
					switch raw {
						case TInt:
							var code = switch constant.expression {
								case TIntLiteral(value): value;
								default: throw "Noninteger raw constant";
							};
							if (seen.exists(code))
								continue;
							seen.set(code, true);
							cases.push({
								value: constant,
								subjectBinding: null,
								arrayPattern: null,
								isCatchAll: false,
								guard: null,
								statements: [TReturn(present, span)],
								enumName: null,
								constructorIndex: -1,
								bindings: [],
								predicates: [],
								span: span
							});
						default:
							statements.push(TIf(new TypedExpression(TEqual(input, constant), TBool, span), [TReturn(present, span)], [], span));
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
				name: helper, role: OtherFunction,
				origin: request.origin,
				originKind: Helper,
				owner: null,
				isStatic: true,
				isConstructor: false,
				isInline: true,
				arguments: [{name: "value", type: inputType}],
				result: outputType,
				statements: statements,
				cells: [],
				cellCaptures: [],
				span: span
			};
			generated.set(helper, fn);
			result.push(fn);
		}
		return result;
	}
}
