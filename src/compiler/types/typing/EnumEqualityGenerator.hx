package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.Provides.ProviderOperation;
import compiler.Provides;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.TypingSession.EqualityRequest;
import haxe.crypto.Sha256;

/** Generates declared enum equality and the separate structural Type.enumEq operation. */
class EnumEqualityGenerator {
	public static inline final EQUALS_PREFIX = "$enum-equals:";
	public static inline final REFLECTIVE_PREFIX = "$enum-reflect-equals:";

	/** Both generated operations keep a semantic value signature when eligible enums become inline values. */
	public static function equalsName(type:CompilerType):String
		return EQUALS_PREFIX + Sha256.encode(compiler.semantic.SemanticSignature.type(type)).substr(0, 32);

	public static function reflectiveName(type:CompilerType):String
		return REFLECTIVE_PREFIX + Sha256.encode(compiler.semantic.SemanticSignature.type(type)).substr(0, 32);

	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void
		requestNamed(session, equalsName(type), type, origin, span);

	public static function requestReflective(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void
		requestNamed(session, reflectiveName(type), type, origin, span);

	static function requestNamed(session:TypingSession, name:String, type:CompilerType, origin:String, span:SourceSpan):Void {
		if (!session.enumEqualityRequests.exists(name))
			session.enumEqualityRequests.set(name, {type: type, origin: origin, span: span});
	}

	public static function generate(session:TypingSession, typer:BodyTyper):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		while (true) {
			var pending = [
				for (name in session.enumEqualityRequests.keys())
					if (!generated.exists(name)) name
			];
			if (pending.length == 0)
				break;
			pending.sort(Reflect.compare);
			for (name in pending) {
				var request = session.enumEqualityRequests.get(name);
				if (request == null)
					throw 'Missing enum equality request "$name"';
				var owner = compiler.QualifiedName.parent(request.origin),
					context = session.enterBody(request.origin, null, owner == null ? "$enum-equality" : owner);
				try {
					var reflective = name == reflectiveName(request.type),
						custom = reflective ? null : EnumConformanceMethods.method(session, request.type, "equals");
					generated.set(name, equalityFunction(session, request, reflective));
					if (custom != null) {
						var customName = EnumConformanceMethods.name(request.type, "equals");
						if (!generated.exists(customName))
							generated.set(customName, EnumConformanceMethods.typeMethod(session, typer, request.type, custom, name));
					}
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

	static function equalityFunction(session:TypingSession, req:EqualityRequest, reflective:Bool):TypedFunction {
		var type = req.type,
			span = session.helperSpan(type, req.span),
			left = new TypedExpression(TLocal("left"), type, span),
			right = new TypedExpression(TLocal("right"), type, span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNullable(element) if (enumType(element)):
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
					leftAbsent = new TypedExpression(TEqual(left, nil), TBool, span),
					rightAbsent = new TypedExpression(TEqual(right, nil), TBool, span),
					leftValue = new TypedExpression(TCast(left), element, span),
					rightValue = new TypedExpression(TCast(right), element, span);
				if (reflective)
					requestReflective(session, element, req.origin, span);
				else
					request(session, element, req.origin, span);
				statements.push(TIf(leftAbsent, [TReturn(rightAbsent, span)], [], span));
				statements.push(TIf(rightAbsent, [TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
				statements.push(TReturn(call(element, leftValue, rightValue, span, reflective), span));
			case TInstance(NominalKind.Enum, name, _):
				var declaration = session.enumDecls.get(name);
				if (declaration == null)
					BodyTyper.fail("E1025", 'Type.enumEq cannot resolve enum "$name"', span);
				var custom = reflective ? null : EnumConformanceMethods.method(session, type, "equals");
				if (custom != null) {
					statements.push(TReturn(new TypedExpression(TCall(EnumConformanceMethods.name(type, "equals"), [left, right]), TBool, span), span));
				} else {
					var leftIndex = new TypedExpression(TEnumIndex(left), TInt, span),
						rightIndex = new TypedExpression(TEnumIndex(right), TInt, span);
					statements.push(TIf(new TypedExpression(TNot(new TypedExpression(TEqual(leftIndex, rightIndex), TBool, span)), TBool, span),
						[TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
					for (constructorIndex in 0...declaration.cases.length) {
						var constructor = declaration.cases[constructorIndex],
							body:Array<TypedStatement> = [];
						for (fieldIndex in 0...constructor.params.length) {
							var parameter = constructor.params[fieldIndex],
								fieldType = session.representation.enumParameterType(declaration.typeParameters, parameter, type),
								storageType = session.representation.enumStorageType(declaration.typeParameters, parameter, type),
								leftField = session.representation.boundaryCast(new TypedExpression(TEnumField(left, constructorIndex, fieldIndex),
									storageType, span), fieldType),
								rightField = session.representation.boundaryCast(new TypedExpression(TEnumField(right, constructorIndex, fieldIndex),
									storageType, span), fieldType),
								comparison = compareField(session, fieldType, leftField, rightField, req, reflective);
							body.push(TIf(new TypedExpression(TNot(comparison), TBool, span),
								[TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
						}
						body.push(TReturn(new TypedExpression(TBoolLiteral(true), TBool, span), span));
						var selected = new TypedExpression(TEqual(leftIndex, new TypedExpression(TIntLiteral(constructorIndex), TInt, span)), TBool, span);
						statements.push(TIf(selected, body, [], span));
					}
					statements.push(TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span));
				}
			default:
				BodyTyper.fail("E1025", 'Type.enumEq requires an enum value, got "${compiler.semantic.SemanticSignature.display(type)}"', span);
		}
		return {
			name: reflective ? reflectiveName(type) : equalsName(type),
			origin: req.origin,
			originKind: Helper,
			typeArguments: null,
			owner: null,
			isStatic: true,
			isConstructor: false,
			provides: Serves(type, reflective ? ReflectEquals : Equals),
			arguments: [
				{
					name: "left",
					type: type
				},
				{name: "right", type: type}
			],
			result: TBool,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: span
		};
	}

	static function compareField(session:TypingSession, type:CompilerType, left:TypedExpression, right:TypedExpression, requestInfo:EqualityRequest,
			reflective:Bool):TypedExpression {
		if (enumType(type)) {
			if (reflective)
				requestReflective(session, type, requestInfo.origin, requestInfo.span);
			else
				request(session, type, requestInfo.origin, requestInfo.span);
			return call(type, left, right, requestInfo.span, reflective);
		}
		if (DeclaredConformance.usesEquality(session, type)) {
			ValueEqualityGenerator.request(session, type, requestInfo.origin, requestInfo.span);
			return new TypedExpression(TCall(ValueEqualityGenerator.equalsName(type), [left, right]), TBool, requestInfo.span);
		}
		return switch type {
			case TNullable(element) if (enumType(element)):
				if (reflective)
					requestReflective(session, element, requestInfo.origin, requestInfo.span);
				else
					request(session, element, requestInfo.origin, requestInfo.span);
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, left.span)), type, left.span),
					leftAbsent = new TypedExpression(TEqual(left, nil), TBool, left.span),
					rightAbsent = new TypedExpression(TEqual(right, nil), TBool, left.span),
					leftValue = new TypedExpression(TCast(left), element, left.span),
					rightValue = new TypedExpression(TCast(right), element, left.span),
					absentResult = new TypedExpression(TEqual(leftAbsent, rightAbsent), TBool, left.span),
					presentResult = call(element, leftValue, rightValue, left.span, reflective);
				new TypedExpression(TConditional(leftAbsent, absentResult,
					new TypedExpression(TConditional(rightAbsent, new TypedExpression(TBoolLiteral(false), TBool, left.span), presentResult), TBool,
						left.span)),
					TBool, left.span);
			case _: new TypedExpression(TEqual(left, right), TBool, left.span);
		};
	}

	static function enumType(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Enum, _, _): true;
			default: false;
		};

	static function call(type:CompilerType, left:TypedExpression, right:TypedExpression, span:SourceSpan, reflective:Bool):TypedExpression
		return new TypedExpression(TCall(reflective ? reflectiveName(type) : equalsName(type), [left, right]), TBool, span);
}
