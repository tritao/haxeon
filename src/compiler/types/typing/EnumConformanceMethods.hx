package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.syntax.Ast.AstFunction;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedFunction;
import haxe.crypto.Sha256;
import compiler.Source.SourceSpan;

/** Handwritten enum conformance methods lower to statically dispatched functions over the enum value. */
class EnumConformanceMethods {
	public static function method(session:TypingSession, type:CompilerType, name:String):Null<AstFunction> {
		return switch type {
			case TInstance(NominalKind.Enum, owner, _):
				var declaration = session.enumDecls.get(owner), found:Null<AstFunction> = null;
				if (declaration != null && declaration.methods != null)
					for (candidate in declaration.methods) if (candidate.name == name) found = candidate;
				found;
			default: null;
		};
	}

	public static function name(type:CompilerType, method:String):String
		return "$enum-custom:" + method + ":" + Sha256.encode(compiler.semantic.SemanticSignature.type(type)).substr(0, 32);

	public static function request(session:TypingSession, type:CompilerType, method:String, origin:String, span:SourceSpan):Void {
		var key = name(type, method);
		if (!session.enumMethodRequests.exists(key))
			session.enumMethodRequests.set(key, {type: type, method: method, origin: origin, span: span});
	}

	public static function generate(session:TypingSession, typer:BodyTyper):Array<TypedFunction> {
		var generated:Map<String, TypedFunction> = [];
		while (true) {
			var pending = [for (key in session.enumMethodRequests.keys()) if (!generated.exists(key)) key];
			if (pending.length == 0) break;
			pending.sort(Reflect.compare);
			for (key in pending) {
				var requested = session.enumMethodRequests.get(key);
				if (requested == null) throw 'Missing enum method request "$key"';
				var implementation = method(session, requested.type, requested.method);
				if (implementation == null) throw 'Missing enum method implementation "$key"';
				generated.set(key, typeMethod(session, typer, requested.type, implementation, requested.origin));
			}
		}
		var keys = [for (key in generated.keys()) key];
		keys.sort(Reflect.compare);
		return [for (key in keys) generated.get(key)];
	}

	public static function typeMethod(session:TypingSession, typer:BodyTyper, type:CompilerType, method:AstFunction, origin:String):TypedFunction {
		return switch type {
			case TInstance(NominalKind.Enum, owner, arguments):
				var declaration = session.enumDecls.get(owner), substitutions:Map<String, CompilerType> = [];
				if (declaration == null) throw 'Missing enum declaration "$owner"';
				for (index in 0...declaration.typeParameters.length)
					substitutions.set(declaration.typeParameters[index], index < arguments.length ? arguments[index]
						: TTypeParameter(owner, declaration.typeParameters[index]));
				var typed = typer.typeFunction(method, owner, true, substitutions, name(type, method.name), type);
				{
					name: typed.name, role: OtherFunction, origin: origin, originKind: Helper, typeArguments: null, owner: null,
					isStatic: true, isConstructor: false, isInline: typed.isInline, isKept: false, isExposed: false,
					arguments: typed.arguments, result: typed.result, statements: typed.statements,
					cells: typed.cells, cellCaptures: typed.cellCaptures, span: typed.span
				};
			default: throw 'Invalid enum conformance method receiver "$type"';
		};
	}
}
