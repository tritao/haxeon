package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.TypingSession.EqualityRequest;

/** Emits the single compiler-selected hash implementation for each Hashable type. */
class HashGenerator {
	public static inline final HASH_PREFIX = "$hash$value$equality:";

	public static function hashName(type:CompilerType):String
		return "$hash" + ValueEqualityGenerator.equalsName(type);

	public static function isHashName(name:String):Bool
		return StringTools.startsWith(name, HASH_PREFIX);

	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void {
		var name = hashName(type);
		if (!session.hashRequests.exists(name))
			session.hashRequests.set(name, {type: type, origin: origin, span: span});
	}

	public static function generate(session:TypingSession):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		while (true) {
			var pending = [for (name in session.hashRequests.keys()) if (!generated.exists(name)) name];
			if (pending.length == 0)
				break;
			pending.sort(Reflect.compare);
			for (name in pending) {
				var requested = session.hashRequests.get(name);
				if (requested == null)
					throw 'Missing hash-generation request "$name"';
				var owner = compiler.QualifiedName.parent(requested.origin),
					context = session.enterBody(requested.origin, null, owner == null ? "$hash" : owner);
				try {
					generated.set(name, hashFunction(session, requested));
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

	static function hashFunction(session:TypingSession, req:EqualityRequest):TypedFunction {
		var type = req.type, span = req.span,
			value = new TypedExpression(TLocal("value"), type, span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNativeScalar(name) if (name == "f32" || name == "f64"):
				request(session, TFloat, req.origin, span);
				statements.push(TReturn(call(TFloat, new TypedExpression(TCast(value), TFloat, span), span), span));
			case TInt, TBool, TNativeScalar(_):
				statements.push(TReturn(primitiveHash(type, value, span), span));
			case TInt64:
				statements.push(TReturn(new TypedExpression(TCall("haxe.Int64.toInt", [value]), TInt, span), span));
			case TFloat:
				statements = floatHashStatements(value, span);
			case TString:
				statements = stringHashStatements(value, span);
			case TAbstract(_, _, representation):
				var castExpression = new TypedExpression(TCast(value), representation, span);
				request(session, representation, req.origin, span);
				statements.push(TReturn(call(representation, castExpression, span), span));
			case TNullable(element):
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
					absent = new TypedExpression(TEqual(value, nil), TBool, span),
					present = new TypedExpression(TCast(value), element, span);
				request(session, element, req.origin, span);
				statements.push(TIf(absent, [TReturn(new TypedExpression(TIntLiteral(0), TInt, span), span)], [], span));
				statements.push(TReturn(call(element, present, span), span));
			case TInstance(NominalKind.Class, name, arguments):
				var declaration = session.classDecls.get(name);
				if (declaration == null)
					BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "$name": declaration is unavailable', span);
				if (!session.relations.isValueClass(type)) {
					var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
						absent = new TypedExpression(TEqual(value, nil), TBool, span);
					statements.push(TIf(absent, [TReturn(new TypedExpression(TIntLiteral(0), TInt, span), span)], [], span));
				}
				var custom = false;
				for (method in declaration.methods)
					if (method.name == "hash")
						custom = true;
				if (custom) {
					statements.push(TReturn(new TypedExpression(TMethodCall(value, name + ".hash", []), TInt, span), span));
				} else {
					var hashName = "$hashValue";
					statements.push(TVar(hashName, new TypedExpression(TIntLiteral(17), TInt, span), span));
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length)
					substitutions.set(declaration.name + "." + declaration.typeParameters[index],
						index < arguments.length ? arguments[index] : TTypeParameter(declaration.name, declaration.typeParameters[index]));
					for (field in DiffIntrinsics.storedFields(declaration)) {
						var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(name, field), field.span, substitutions),
							fieldValue = new TypedExpression(TField(value, field.name), fieldType, span);
						request(session, fieldType, req.origin, field.span);
						var running = new TypedExpression(TLocal(hashName), TInt, span),
							mixed = new TypedExpression(TAdd(new TypedExpression(TMul(running,
								new TypedExpression(TIntLiteral(31), TInt, span)), TInt, span), call(fieldType, fieldValue, span)), TInt, span);
						statements.push(TAssign(hashName, mixed, span));
					}
					statements.push(TReturn(new TypedExpression(TLocal(hashName), TInt, span), span));
				}
			default:
				BodyTyper.fail("E1025", 'Cannot synthesize Hashable for type "${compiler.semantic.SemanticSignature.display(type)}"', span);
		}
		return {
			name: hashName(type), origin: req.origin, originKind: Helper, typeArguments: null,
			owner: null, isStatic: true, isConstructor: false,
			arguments: [{name: "value", type: type}], result: TInt,
			statements: statements, cells: [], cellCaptures: [], span: span
		};
	}

	static function primitiveHash(type:CompilerType, value:TypedExpression, span:SourceSpan):TypedExpression
		return switch type {
			case TBool:
				new TypedExpression(TConditional(value, new TypedExpression(TIntLiteral(1231), TInt, span), new TypedExpression(TIntLiteral(1237), TInt, span)),
					TInt, span);
			case TNativeScalar("c_bool"):
				new TypedExpression(TConditional(new TypedExpression(TCast(value), TBool, span), new TypedExpression(TIntLiteral(1231), TInt, span),
					new TypedExpression(TIntLiteral(1237), TInt, span)), TInt, span);
			case TNativeScalar(_): new TypedExpression(TCast(value), TInt, span);
			case _: value;
		};

	static function call(type:CompilerType, value:TypedExpression, span:SourceSpan):TypedExpression
		return new TypedExpression(TCall(hashName(type), [value]), TInt, span);

	static function floatHashStatements(value:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		var same = new TypedExpression(TEqual(value, value), TBool, span),
			zero = new TypedExpression(TFloatLiteral(0.0), TFloat, span),
			isZero = new TypedExpression(TEqual(value, zero), TBool, span),
			limit = new TypedExpression(TFloatLiteral(2147483647.0), TFloat, span),
			negativeLimit = new TypedExpression(TFloatLiteral(-2147483647.0), TFloat, span),
			clamped = new TypedExpression(TConditional(
				new TypedExpression(TLessEqual(value, negativeLimit), TBool, span), negativeLimit,
				new TypedExpression(TConditional(new TypedExpression(TLessEqual(limit, value), TBool, span), limit, value), TFloat, span)),
				TFloat, span),
			whole = new TypedExpression(TFloatToInt(clamped), TInt, span),
			fraction = new TypedExpression(TFloatToInt(new TypedExpression(TMul(
				new TypedExpression(TSub(value, new TypedExpression(TIntToFloat(whole), TFloat, span)), TFloat, span),
				new TypedExpression(TFloatLiteral(16777216.0), TFloat, span)), TFloat, span)), TInt, span),
			combined = new TypedExpression(TAdd(new TypedExpression(TMul(whole, new TypedExpression(TIntLiteral(31), TInt, span)), TInt, span),
				fraction), TInt, span);
		return [
			TIf(new TypedExpression(TNot(same), TBool, span), [TReturn(new TypedExpression(TIntLiteral(0x7fc00000), TInt, span), span)], [], span),
			TIf(isZero, [TReturn(new TypedExpression(TIntLiteral(0), TInt, span), span)], [], span),
			TReturn(combined, span)
		];
	}

	static function stringHashStatements(value:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		var length = new TypedExpression(TStringLength(value), TInt, span),
			hash = new TypedExpression(TLocal("$string-hash"), TInt, span),
			index = new TypedExpression(TLocal("$string-index"), TInt, span),
			char = new TypedExpression(TStringCharCodeAt(value, index), TInt, span),
			nextHash = new TypedExpression(TAdd(new TypedExpression(TMul(hash, new TypedExpression(TIntLiteral(31), TInt, span)), TInt, span),
				char), TInt, span),
			nextIndex = new TypedExpression(TAdd(index, new TypedExpression(TIntLiteral(1), TInt, span)), TInt, span);
		return [
			TVar("$string-hash", length, span),
			TVar("$string-index", new TypedExpression(TIntLiteral(0), TInt, span), span),
			TWhile(new TypedExpression(TLess(index, length), TBool, span), [
				TAssign("$string-hash", nextHash, span),
				TAssign("$string-index", nextIndex, span)
			], span),
			TReturn(hash, span)
		];
	}
}
