package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.InlineConstantEvaluator;

/** Closed integer sets have value-returning operations; no reader or mutation wrapper is needed. */
@:access(compiler.types.typing.BodyTyper)
class FlagsGenerator {
	public static inline final PREFIX = "$flags:";

	public static function conforms(session:TypingSession, declaration:AstEnumAbstract):Bool
		return DeclaredConformance.has(session, TAbstract(declaration.name, [], session.declarations.resolve(declaration.underlying, declaration.span)),
			"Flags");

	public static function isMember(method:String, isStatic:Bool):Bool
		return isStatic ? method == "empty" || method == "fromRaw" : switch method {
			case "rawValue", "isEmpty", "isSingle", "contains", "insert", "remove", "toString": true;
			default: false;
		};

	public static function signature(owner:String, method:String):{arguments:Array<CompilerType>, result:CompilerType} {
		var value:CompilerType = TAbstract(owner, [], TInt);
		return switch method {
			case "empty": {arguments: [], result: value};
			case "fromRaw": {arguments: [TInt], result: value};
			case "rawValue": {arguments: [value], result: TInt};
			case "isEmpty", "isSingle": {arguments: [value], result: TBool};
			case "contains": {arguments: [value, value], result: TBool};
			case "insert", "remove", "$or", "$and": {arguments: [value, value], result: value};
			case "toString": {arguments: [value], result: TString};
			default: throw 'Unknown Flags member "$method"';
		};
	}

	static function code(typer:BodyTyper, declaration:AstEnumAbstract, value:compiler.syntax.Ast.AstEnumAbstractValue):Int {
		var constant = InlineConstantEvaluator.evaluate(EnumAbstractValues.raw(typer, declaration, value));
		if (constant != null)
			switch constant.expression {
				case TIntLiteral(code):
					return code;
				default:
			}
		throw new compiler.Diagnostic.CompileError(new compiler.Diagnostic("E1002", "Flags requires compile-time Int constants", value.span));
	}

	static function single(value:Int):Bool
		return value != 0 && (value & (value - 1)) == 0;

	public static function validate(session:TypingSession, typer:BodyTyper, declaration:AstEnumAbstract):Void {
		if (!conforms(session, declaration))
			return;
		if (!compiler.types.TypeRelations.equals(typer.lowerType(declaration.underlying), TInt))
			BodyTyper.fail("E1025", "Flags requires an Int enum abstract", declaration.span);
		if (declaration.fromTypes.length != 0 || declaration.toTypes.length != 0)
			BodyTyper.fail("E1025", "Flags enum abstracts cannot declare implicit from/to conversions", declaration.span);
		if (RawRepresentableGenerator.conforms(session, declaration))
			BodyTyper.fail("E1025", "Flags already defines raw conversion; declare Flags without RawRepresentable", declaration.span);
		var mask = 0;
		for (value in declaration.values) {
			if (isMember(value.name, true) || isMember(value.name, false))
				BodyTyper.fail("E1000", 'Constant "${declaration.name}.${value.name}" conflicts with a synthesized Flags member', value.span);
			var bits = code(typer, declaration, value);
			if (single(bits))
				mask |= bits;
		}
		for (value in declaration.values)
			if ((code(typer, declaration, value) & ~mask) != 0)
				BodyTyper.fail("E1025", 'Flags constant "${declaration.name}.${value.name}" contains bits without a declared single-bit constant', value.span);
		session.flagsMasks.set(declaration.name, mask);
	}

	public static function request(session:TypingSession, owner:String, method:String, span:SourceSpan):String {
		var name = PREFIX + owner + ":" + method;
		if (!session.flagsRequests.exists(name))
			session.flagsRequests.set(name, {
				owner: owner,
				method: method,
				origin: session.generatedFunctionOrigin(),
				span: span
			});
		return name;
	}

	public static function generate(session:TypingSession, typer:BodyTyper, generated:Map<String, TypedFunction>):Array<TypedFunction> {
		var pending = [for (name in session.flagsRequests.keys()) if (!generated.exists(name)) name];
		pending.sort(Reflect.compare);
		var functions:Array<TypedFunction> = [];
		for (name in pending) {
			var request = session.flagsRequests.get(name),
				declaration = session.enumAbstractDecls.get(request.owner);
			if (declaration == null || !conforms(session, declaration))
				throw 'Missing Flags declaration "${request.owner}"';
			var span = declaration.span, method = request.method, info = signature(request.owner, method), arguments = [
				for (i in 0...info.arguments.length) {name: i == 0 ? "value" : "flag", type: info.arguments[i]}
			], statements:Array<TypedStatement> = [];
			function expression(kind:TypedExpressionKind, type:CompilerType):TypedExpression
				return new TypedExpression(kind, type, span);
			function integer(value:Int):TypedExpression
				return expression(TIntLiteral(value), TInt);
			function text(value:String):TypedExpression
				return expression(TStringLiteral(value), TString);
			function binary(kind:TypedExpressionKind):TypedExpression
				return expression(kind, TInt);
			function boolean(kind:TypedExpressionKind):TypedExpression
				return expression(kind, TBool);
			function equal(a:TypedExpression, b:TypedExpression):TypedExpression
				return boolean(TEqual(a, b));
			function not(value:TypedExpression):TypedExpression
				return boolean(TNot(value));
			function wrap(value:TypedExpression):TypedExpression
				return expression(TAbiCast(value), TAbstract(request.owner, [], TInt));
			var input = method == "empty" ? integer(0) : expression(TLocal("value"), info.arguments[0]),
				bits = method == "fromRaw" ? input : expression(TAbiCast(input), TInt),
				flag = expression(TAbiCast(expression(TLocal("flag"), TAbstract(request.owner, [], TInt))), TInt),
				result:Null<TypedExpression> = null;
			switch method {
				case "empty":
					result = wrap(integer(0));
				case "rawValue":
					result = bits;
				case "isEmpty":
					result = equal(bits, integer(0));
				case "isSingle":
					result = boolean(TAnd(not(equal(bits, integer(0))), equal(binary(TBitAnd(bits, binary(TSub(bits, integer(1))))), integer(0))));
				case "contains":
					result = equal(binary(TBitAnd(bits, flag)), flag);
				case "insert", "$or":
					result = wrap(binary(TBitOr(bits, flag)));
				case "remove":
					result = wrap(binary(TBitAnd(bits, binary(TBitXor(flag, integer(-1))))));
				case "$and":
					result = wrap(binary(TBitAnd(bits, flag)));
				case "fromRaw":
					var mask = session.flagsMasks.get(request.owner);
					if (mask == null)
						throw "Flags mask was not validated";
					statements.push(TIf(not(equal(binary(TBitAnd(bits, integer(~mask))), integer(0))),
						[TThrow(text('Unknown bits in ${request.owner}.fromRaw'), span)], [], span));
					result = wrap(bits);
				case "toString":
					for (value in declaration.values)
						statements.push(TIf(equal(bits, integer(code(typer, declaration, value))), [TReturn(text(request.owner + "." + value.name), span)],
							[], span));
					statements.push(TIf(equal(bits, integer(0)), [TReturn(text(request.owner + "[]"), span)], [], span));
					statements.push(TVar("text", text(request.owner + "["), span));
					statements.push(TVar("first", expression(TBoolLiteral(true), TBool), span));
					var seen:Map<Int, Bool> = [];
					for (value in declaration.values) {
						var bit = code(typer, declaration, value);
						if (!single(bit) || seen.exists(bit))
							continue;
						seen.set(bit, true);
						var separator = expression(TConditional(expression(TLocal("first"), TBool), text(""), text(" | ")), TString),
							combined = expression(TAdd(expression(TLocal("text"), TString), expression(TAdd(separator, text(value.name)), TString)), TString);
						statements.push(TIf(not(equal(binary(TBitAnd(bits, integer(bit))), integer(0))), [
							TAssign("text", combined, span),
							TAssign("first", expression(TBoolLiteral(false), TBool), span)
						], [], span));
					}
					result = expression(TAdd(expression(TLocal("text"), TString), text("]")), TString);
				default:
					throw 'Unknown Flags helper "$method"';
			}
			if (result == null)
				throw "Missing Flags helper result";
			statements.push(TReturn(result, span));
			var fn:TypedFunction = {
				name: name, role: ProviderFunction(TAbstract(request.owner, [], TInt), compiler.Provides.ProviderOperation.detailed(compiler.Provides.ProviderOperation.Flags, method)),
				origin: request.origin,
				originKind: Helper,
				owner: null,
				isStatic: true,
				isConstructor: false,
				isInline: true,
				arguments: arguments,
				result: info.result,
				statements: statements,
				cells: [],
				cellCaptures: [],
				span: span
			};
			generated.set(name, fn);
			functions.push(fn);
		}
		return functions;
	}
}
