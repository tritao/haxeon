package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.TemporaryLocal;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/**
 * Haxe's `Type.createEnumIndex`, `Type.createEnum` and `Type.allEnums` on an enum named where they are called
 * (`Type.createEnumIndex(Color, i)`), written out as a choice on the constructor, so they need no runtime enum descriptor.
 * They throw what HashLink's `Type` throws: for an index out of range, an unknown name, a constructor with arguments
 * given none, or a count of arguments its constructor does not take. An enum held as a value (`Enum<T>`) needs the
 * descriptors of `docs/design/TYPE_VALUES.md`.
 */
class EnumCreation {
	public static function handles(name:String):Bool
		return name == "Type.createEnumIndex" || name == "Type.createEnum" || name == "Type.allEnums";

	public static function expand(session:TypingSession, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, expectedType:Null<CompilerType>):AstExpression {
		var allEnums = name == "Type.allEnums";
		if (allEnums ? arguments.length != 1 : arguments.length < 2 || arguments.length > 3)
			fail("E1008",
				'Function "$name" expects ${allEnums ? "1 argument" : "2 or 3 arguments"}, got ${arguments.length}',
				span);
		var enumName = switch arguments[0] {
			case Variable(value, _) if (session.enumDecls.exists(value)): value;
			default:
				fail("E1009",
					'$name needs an enum named where it is called; an enum held as a value is not supported yet', span);
				"";
		},
			declaration:AstEnum = session.enumDecls.get(enumName),
			displayName = compiler.semantic.SemanticSignature.display(TInstance(NominalKind.Enum, enumName, [])),
			cases = declaration.cases;
		// A generic enum's arguments come from the expected type, as Haxe infers them; with nothing to infer them from, they
		// are Dynamic.
		var inferred = switch expectedType {
			case TInstance(NominalKind.Enum, expectedName, _) | TNullable(TInstance(NominalKind.Enum, expectedName, _)):
				expectedName == enumName;
			case TArray(TInstance(NominalKind.Enum, expectedName, _)): allEnums && expectedName == enumName;
			default: false;
		};
		function typed(value:AstExpression):AstExpression {
			if (declaration.typeParameters.length == 0 || inferred)
				return value;
			var type = AppliedType(enumName, [for (_ in declaration.typeParameters) NamedType("Dynamic")]);
			return CheckType(value, allEnums ? ArrayType(type) : type, span);
		}
		function constructor(index:Int):String
			return enumName + "." + cases[index].name;
		if (allEnums)
			return typed(ArrayLiteral([
				for (index in 0...cases.length)
					if (cases[index].params.length == 0) Variable(constructor(index), span)
			], span));
		function temporary(purpose:String):TemporaryLocal
			return new TemporaryLocal('$'
				+ 'enum-creation:$purpose:${span.start}:${session.currentContext.diffTemporary++}');
		var index = temporary("index"), statements:Array<AstStatement> = [];
		function thrown(message:AstExpression):AstExpression
			return ThrowExpression(message, span);
		// `Type.createEnum` looks the name up first, then creates as `createEnumIndex` does.
		if (name == "Type.createEnum") {
			var constructorName = temporary("name"),
				found:AstExpression = thrown(Add(StringLiteral('Unknown enum constructor $displayName.',
					span), TemporaryVariable(constructorName, span), span));
			var candidate = cases.length;
			while (--candidate >= 0)
				found = Conditional(Equal(TemporaryVariable(constructorName, span),
					StringLiteral(cases[candidate].name, span),
					span), IntegerLiteral(candidate, span), found, span);
			statements.push(TemporaryDeclaration(constructorName, StringType, arguments[1], span));
			statements.push(TemporaryDeclaration(index, IntType, found, span));
		} else {
			statements.push(TemporaryDeclaration(index, IntType, arguments[1], span));
			statements.push(If(Or(Less(TemporaryVariable(index, span), IntegerLiteral(0, span), span),
				GreaterEqual(TemporaryVariable(index, span), IntegerLiteral(cases.length, span), span), span),
				[Throw(Add(StringLiteral('Invalid enum index $displayName.', span), TemporaryVariable(index, span),
				span), span)],
				[], span));
		}
		function choose(of:Int->AstExpression):AstExpression {
			// No index of an enum without constructors is in range.
			if (cases.length == 0)
				return thrown(StringLiteral('Invalid enum index $displayName', span));
			var chosen = of(cases.length - 1), candidate = cases.length - 1;
			while (--candidate >= 0)
				chosen = Conditional(Equal(TemporaryVariable(index, span), IntegerLiteral(candidate, span), span),
					of(candidate),
					chosen, span);
			return chosen;
		}
		var withoutArguments = choose(candidate -> cases[candidate].params.length == 0
			? Variable(constructor(candidate),
			span) : thrown(StringLiteral('Constructor $displayName.${cases[candidate].name} takes parameters', span)));
		if (arguments.length == 2)
			return typed(BlockExpression(statements, withoutArguments, span));
		var parameters = temporary("parameters"), given = TemporaryVariable(parameters, span);
		statements.push(TemporaryDeclaration(parameters, NullableType(ArrayType(NamedType("Dynamic"))), arguments[2],
			span));
		var withArguments = choose(candidate -> {
			var count = cases[candidate].params.length,
				created = count == 0 ? Variable(constructor(candidate), span) : Call(constructor(candidate), [
					for (field in 0...count)
						Index(given, IntegerLiteral(field, span), span)
				], span);
			Conditional(Equal(Member(given, "length", span), IntegerLiteral(count, span), span), created,
				thrown(Add(Add(StringLiteral('Constructor $displayName.${cases[candidate].name} does not takes ', span),
				Member(given, "length", span), span), StringLiteral(" parameters", span), span)), span);
		});
		return typed(BlockExpression(statements,
			Conditional(Or(Equal(given, NullLiteral(span), span),
			Equal(Member(given, "length", span), IntegerLiteral(0, span),
			span), span), withoutArguments, withArguments, span), span));
	}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
