package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.Scope;

/**
 * Haxe's `Type.enumConstructor` and `Type.enumParameters` on a value whose enum type is known where it is typed. They read
 * only the value: its constructor's name, and a new `Array<Dynamic>` of its arguments in declaration order (`[]` for a
 * constructor without any, and `null` for an optional one left out), as HashLink's `Type` makes them. The array is the
 * caller's: writing to it does not change the value.
 *
 * Both are written out where they are called, as a choice on the value's constructor index, so they need no runtime type
 * information and are the same on every backend; inside a generic function an argument of the enum's type parameter is boxed
 * as its representation is, by the elaboration pass. A value of `Dynamic` (or Haxe's `EnumValue`) needs the enum's runtime
 * descriptor, which is the Type API's next step (`docs/design/TYPE_VALUES.md`).
 */
class EnumReflection {
	/** The enum type of `value`, or null when it is not an enum value; a `Null<E>` value reads as `E`. */
	public static function enumType(type:CompilerType):Null<CompilerType>
		return switch type {
			case TInstance(NominalKind.Enum, _, _): type;
			case TNullable(inner = TInstance(NominalKind.Enum, _, _)): inner;
			default: null;
		};

	/** `Type.enumConstructor(value)`: the name of the constructor `value` was made with. */
	public static function constructorName(session:TypingSession, bodyTyper:BodyTyping, value:TypedExpression,
			scope:Scope, span:SourceSpan):TypedExpression {
		var cases = declaration(session, value.type).cases;
		function name(index:Int):TypedExpression
			return new TypedExpression(TStringLiteral(cases[index].name), TString, span);
		if (cases.length == 1)
			return new TypedExpression(TBlockExpression([TExpression(value, span)], name(0)), TString, span);
		var inner = new Scope(scope),
			index = bind(bodyTyper, inner, "__haxeon_enum_index" + span.start,
				new TypedExpression(TEnumIndex(value), TInt, span), span);
		return new TypedExpression(TBlockExpression([index.statement], choose(index.local, cases.length, name, TString,
			span)), TString, span);
	}

	/** `Type.enumParameters(value)`: a new array of the arguments `value` was made with, each as `Dynamic`. */
	public static function parameters(session:TypingSession, bodyTyper:BodyTyping, value:TypedExpression, scope:Scope,
			span:SourceSpan):TypedExpression {
		var type = value.type,
			enumDecl = declaration(session, type),
			result = TArray(TDynamic),
			inner = new Scope(scope),
			held = bind(bodyTyper, inner, "__haxeon_enum_value" + span.start, value, span),
			statements = [held.statement];
		function arguments(constructor:Int):TypedExpression {
			var parameters = enumDecl.cases[constructor].params, values:Array<TypedExpression> = [];
			for (field in 0...parameters.length) {
				var parameter = parameters[field],
					semantic = session.representation.enumParameterType(enumDecl.typeParameters, parameter, type);
				// A `Void` payload is stored as nothing (`ProgramFacts.enumVoidPayloads`), so it is no argument here either.
				if (VoidArguments.isVoid(semantic))
					continue;
				var stored = new TypedExpression(TEnumField(held.local, constructor, field),
					session.representation.enumStorageType(enumDecl.typeParameters, parameter, type), span);
				values.push(bodyTyper.coerce(session.representation.boundaryCast(stored, semantic), TDynamic,
					"Type.enumParameters argument", DiagnosticCode.ASSIGNMENT_OR_BINDING));
			}
			return new TypedExpression(TArrayLiteral(values), result, span);
		}
		if (enumDecl.cases.length == 1)
			return new TypedExpression(TBlockExpression(statements, arguments(0)), result, span);
		var index = bind(bodyTyper, inner, "__haxeon_enum_index" + span.start,
			new TypedExpression(TEnumIndex(held.local), TInt, span), span);
		statements.push(index.statement);
		return new TypedExpression(TBlockExpression(statements, choose(index.local, enumDecl.cases.length, arguments,
			result, span)), result, span);
	}

	static function declaration(session:TypingSession, type:CompilerType):compiler.syntax.Ast.AstEnum
		return switch type {
			case TInstance(NominalKind.Enum, name, _):
				var found = session.enumDecls.get(name);
				if (found == null)
					throw new InternalError('Missing enum declaration "$name"');
				found;
			default: throw new InternalError("Enum reflection of a value that is not an enum");
		};

	/** A local of `inner` holding `value`, read as `local`. */
	static function bind(bodyTyper:BodyTyping, inner:Scope, name:String, value:TypedExpression,
			span:SourceSpan):{
				statement:TypedStatement,
				local:TypedExpression
			} {
		var binding = inner.define(name, value.type, span);
		bodyTyper.bindCell(binding, value.type);
		var id = binding.id;
		return {statement: TVar(id, value, span), local: new TypedExpression(TLocal(id), value.type, span)};
	}

	/** `of(index)` for the constructor index held by `index`, one of `0...count`: the last needs no test. */
	static function choose(index:TypedExpression, count:Int, of:Int->TypedExpression, type:CompilerType,
			span:SourceSpan):TypedExpression {
		var chosen = of(count - 1);
		var constructor = count - 2;
		while (constructor >= 0) {
			var matches = new TypedExpression(TEqual(index, new TypedExpression(TIntLiteral(constructor), TInt, span)),
				TBool, span);
			chosen = new TypedExpression(TConditional(matches, of(constructor), chosen), type, span);
			constructor--;
		}
		return chosen;
	}
}
