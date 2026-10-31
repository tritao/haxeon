package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.TypingSession.EqualityRequest;

/** Fieldwise language equality: each field uses its own `==`, including reference identity. */
class ValueEqualityGenerator {
	public static function equalsName(type:CompilerType):String
		return "$value" + EqualityGenerator.equalsName(type);

	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void {
		var name = equalsName(type);
		if (!session.valueEqualityRequests.exists(name))
			session.valueEqualityRequests.set(name, {type: type, origin: origin, span: span});
	}

	/** Field comparisons may request nested value helpers. Process new requests until no more are needed. */
	public static function generate(session:TypingSession,
			compare:(TypedExpression, TypedExpression, SourceSpan)->TypedExpression):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		while (true) {
			var pending = [for (name in session.valueEqualityRequests.keys()) if (!generated.exists(name)) name];
			if (pending.length == 0)
				break;
			pending.sort(Reflect.compare);
			for (name in pending) {
				var requested = session.valueEqualityRequests.get(name);
				if (requested == null)
					throw 'Missing value equality request "$name"';
				// Helpers can originate in a lambda after its typing context has already been popped.
				var owner = compiler.QualifiedName.parent(requested.origin),
					context = session.enterBody(requested.origin, null, owner == null ? "$value-equality" : owner);
				try {
					generated.set(name, compareFunction(session, requested, compare));
					session.leaveBody(context);
				} catch (error:Dynamic) {
					session.leaveBody(context);
					throw error;
				}
			}
		}
		var names = [for (name in generated.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) generated.get(name)];
	}

	static function compareFunction(session:TypingSession, request:EqualityRequest,
			compare:(TypedExpression, TypedExpression, SourceSpan)->TypedExpression):TypedFunction {
		var type = request.type, span = request.span,
			left = new TypedExpression(TLocal("left"), type, span),
			right = new TypedExpression(TLocal("right"), type, span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNullable(element) if (session.relations.isValueClass(element)):
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
					leftAbsent = new TypedExpression(TEqual(left, nil), TBool, span),
					rightAbsent = new TypedExpression(TEqual(right, nil), TBool, span),
					leftValue = new TypedExpression(TCast(left), element, span),
					rightValue = new TypedExpression(TCast(right), element, span);
				statements.push(TIf(leftAbsent, [TReturn(rightAbsent, span)], [], span));
				statements.push(TIf(rightAbsent, [TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
				statements.push(TReturn(compare(leftValue, rightValue, span), span));
			case TInstance(NominalKind.Class, name, _) if (session.relations.isValueClass(type)):
				var declaration = session.classDecls.get(name);
				if (declaration == null)
					throw 'Missing value type declaration "$name"';
				for (field in StructuralIntrinsics.storedFields(declaration, span)) {
					var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(name, field), field.span),
						leftField = new TypedExpression(TField(left, field.name), fieldType, span),
						rightField = new TypedExpression(TField(right, field.name), fieldType, span),
						comparison = compare(leftField, rightField, span);
					statements.push(TIf(new TypedExpression(TNot(comparison), TBool, span),
						[TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
				}
				statements.push(TReturn(new TypedExpression(TBoolLiteral(true), TBool, span), span));
			default:
				throw 'Invalid value equality request for "$type"';
		}
		return {
			name: equalsName(type), origin: request.origin, originKind: Helper, typeArguments: null,
			owner: null, isStatic: true, isConstructor: false,
			arguments: [{name: "left", type: type}, {name: "right", type: type}], result: TBool,
			statements: statements, cells: [], cellCaptures: [], span: span
		};
	}
}
