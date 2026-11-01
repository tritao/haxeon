package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstClass;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.TypingSession.EqualityRequest;
import haxe.crypto.Sha256;

/** Fieldwise language equality: each field uses its own `==`, including reference identity. */
class ValueEqualityGenerator {
	public static function equalsName(type:CompilerType):String
		return "$value$equality:" + Sha256.encode(compiler.semantic.SemanticSignature.type(type)).substr(0, 32);

	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void {
		var name = equalsName(type);
		if (!session.valueEqualityRequests.exists(name))
			session.valueEqualityRequests.set(name, {type: type, origin: origin, span: span});
	}

	/** Field comparisons may request nested value helpers. Process new requests until no more are needed. */
	public static function generate(session:TypingSession,
			compare:(TypedExpression, TypedExpression, SourceSpan)->TypedExpression):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		// Discover the full helper graph from source requests before typing any generated helper. This gives nested
		// helpers the origin of a real caller, so they are emitted into that caller's module and remain traceable when
		// incremental compilation prunes the generated module graph.
		var roots = [for (name in session.valueEqualityRequests.keys()) name];
		roots.sort(Reflect.compare);
		for (name in roots) {
			var root = session.valueEqualityRequests.get(name);
			if (root != null)
				collect(session, root.type, root, session.valueEqualityRequests, new Map());
		}
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

	static function collect(session:TypingSession, type:CompilerType, root:EqualityRequest,
			requests:Map<String, EqualityRequest>, seen:Map<String, Bool>):Void {
		var name = equalsName(type);
		if (seen.exists(name))
			return;
		seen.set(name, true);
		switch type {
			case TNullable(element) if (DeclaredConformance.has(session, element, "Equatable")):
				if (!requests.exists(name)) requests.set(name, {type: type, origin: root.origin, span: root.span});
				collect(session, element, root, requests, seen);
			case TInstance(NominalKind.Class, className, arguments) if (DeclaredConformance.has(session, type, "Equatable")):
				var declaration = session.classDecls.get(className);
				if (declaration == null)
					throw 'Missing value type declaration "$className"';
				if (!requests.exists(name)) requests.set(name, {type: type, origin: root.origin, span: root.span});
				if (!hasHandwrittenEquals(declaration)) {
					var substitutions:Map<String, CompilerType> = [];
					for (index in 0...declaration.typeParameters.length)
						substitutions.set(declaration.name + "." + declaration.typeParameters[index],
							index < arguments.length ? arguments[index] : TTypeParameter(declaration.name, declaration.typeParameters[index]));
					for (field in DiffIntrinsics.storedFields(declaration)) {
						var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(className, field), field.span, substitutions);
						if (needsHelper(session, fieldType))
							collect(session, fieldType, root, requests, seen);
					}
				}
			default:
		}
	}

	static function needsHelper(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TNullable(element): DeclaredConformance.has(session, element, "Equatable");
			case TInstance(NominalKind.Class, _, _): DeclaredConformance.has(session, type, "Equatable");
			default: false;
		};

	static function hasHandwrittenEquals(declaration:AstClass):Bool {
		for (method in declaration.methods)
			if (method.name == "equals") return true;
		return false;
	}

	static function compareFunction(session:TypingSession, request:EqualityRequest,
			compare:(TypedExpression, TypedExpression, SourceSpan)->TypedExpression):TypedFunction {
		var type = request.type, span = request.span,
			left = new TypedExpression(TLocal("left"), type, span),
			right = new TypedExpression(TLocal("right"), type, span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNullable(element) if (DeclaredConformance.has(session, element, "Equatable")):
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
					leftAbsent = new TypedExpression(TEqual(left, nil), TBool, span),
					rightAbsent = new TypedExpression(TEqual(right, nil), TBool, span),
					leftValue = new TypedExpression(TCast(left), element, span),
					rightValue = new TypedExpression(TCast(right), element, span);
				statements.push(TIf(leftAbsent, [TReturn(rightAbsent, span)], [], span));
				statements.push(TIf(rightAbsent, [TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
				statements.push(TReturn(compare(leftValue, rightValue, span), span));
			case TInstance(NominalKind.Class, name, arguments) if (DeclaredConformance.has(session, type, "Equatable")):
				var declaration = session.classDecls.get(name);
				if (declaration == null)
					throw 'Missing value type declaration "$name"';
				if (!session.relations.isValueClass(type)) {
					var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span),
						leftAbsent = new TypedExpression(TEqual(left, nil), TBool, span),
						rightAbsent = new TypedExpression(TEqual(right, nil), TBool, span);
					statements.push(TIf(leftAbsent, [TReturn(rightAbsent, span)], [], span));
					statements.push(TIf(rightAbsent, [TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
				}
				var substitutions:Map<String, CompilerType> = [];
				for (index in 0...declaration.typeParameters.length)
					substitutions.set(declaration.name + "." + declaration.typeParameters[index],
						index < arguments.length ? arguments[index] : TTypeParameter(declaration.name, declaration.typeParameters[index]));
				var custom:Null<AstFunction> = null;
				if (DeclaredConformance.has(session, type, "Equatable"))
					for (method in declaration.methods)
						if (method.name == "equals")
							custom = method;
				if (custom != null) {
					if (custom.isStatic || custom.arguments.length != 1
						|| !compiler.types.TypeRelations.equals(session.declarations.resolve(custom.arguments[0].type, custom.span, substitutions), type)
						|| !compiler.types.TypeRelations.equals(session.declarations.resolve(custom.result, custom.span, substitutions), TBool))
						BodyTyper.fail("E1003", 'Method "$name.equals" must have signature equals(other:$name):Bool', custom.span);
					statements.push(TReturn(new TypedExpression(TMethodCall(left, name + ".equals", [right]), TBool, span), span));
				} else {
					for (field in DiffIntrinsics.storedFields(declaration)) {
					var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(name, field), field.span, substitutions),
							leftField = new TypedExpression(TField(left, field.name), fieldType, span),
							rightField = new TypedExpression(TField(right, field.name), fieldType, span),
							comparison = compare(leftField, rightField, span);
						statements.push(TIf(new TypedExpression(TNot(comparison), TBool, span),
							[TReturn(new TypedExpression(TBoolLiteral(false), TBool, span), span)], [], span));
					}
					statements.push(TReturn(new TypedExpression(TBoolLiteral(true), TBool, span), span));
				}
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
