package compiler.types.typing;

import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedInterface;

/**
	The runtime modules that change how a declared type is represented. A map the typer represents with the specialized owner
	(`TypingSession.requiresSpecializedMap`) needs `RuntimeType.SPECIALIZED_MAP`, and whether the owner can be made depends on
	that module being in the program. Typing a body against a program without it gives the types a different representation
	than typing it with the module, so the module has to be known before any body is typed. It follows from the declarations:
	the types of fields, method and function signatures, interface methods and enum payloads. A map met only inside a body is
	not visible here; the frontend finds it when the body is typed and starts over (see `FrontendCompilation`).
**/
class RepresentationDependencies {
	/** Declarations that need a missing representation module, one entry per declaration: its name and the module. */
	public static function missing(session:TypingSession, classes:Array<TypedClass>, interfaces:Array<TypedInterface>, enums:Array<TypedEnum>,
			functions:Array<AstFunction>):Array<{var functionName:String; var target:String;
		}> {
		var result:Array<{var functionName:String; var target:String;}> = [];
		if (session.classDecls.exists(RuntimeType.SPECIALIZED_MAP))
			return result;
		function need(origin:String, types:Array<CompilerType>):Void {
			for (type in types)
				if (usesSpecializedMap(session, type, [])) {
					result.push({functionName: origin, target: RuntimeType.SPECIALIZED_MAP});
					return;
				}
		}
		for (classDecl in classes) {
			var types = [for (field in classDecl.fields) field.type];
			for (method in classDecl.methods) {
				types.push(method.result);
				for (argument in method.arguments)
					types.push(argument.type);
			}
			need(RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + (classDecl.specializationOrigin == null ? classDecl.name : classDecl.specializationOrigin),
				types);
		}
		for (interfaceDecl in interfaces) {
			var types = [for (method in interfaceDecl.methods) method.result];
			for (method in interfaceDecl.methods)
				for (argument in method.arguments)
					types.push(argument);
			need(RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + interfaceDecl.name, types);
		}
		for (enumDecl in enums) {
			var types:Array<CompilerType> = [];
			for (enumCase in enumDecl.cases)
				for (parameter in enumCase.params)
					types.push(parameter);
			need(RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + enumDecl.name, types);
		}
		for (fn in functions) {
			if (fn.isExtern == true || fn.typeParameters != null && fn.typeParameters.length > 0)
				continue;
			var types = [
				for (argument in fn.arguments) if (declared(argument.type)) session.representation.semanticType(argument.type, null, null)
			];
			if (declared(fn.result))
				types.push(session.representation.semanticType(fn.result, null, null));
			need(fn.name, types);
		}
		return result;
		}

	/** Whether a declared type names its type; an omitted one is inferred from the body. */
	static function declared(type:AstType):Bool
		return switch type {
			case InferredType: false;
			default: true;
		};

	static function usesSpecializedMap(session:TypingSession, type:CompilerType, explored:Array<Array<AnonymousField>>):Bool
		return switch type {
			case TInstance(_, _, arguments): anyUsesSpecializedMap(session, arguments, explored);
			case TAbstract(_, arguments, representation): anyUsesSpecializedMap(session, arguments,
					explored) || usesSpecializedMap(session, representation, explored);
			case TNullable(inner), TArray(inner), TIterator(inner): usesSpecializedMap(session, inner, explored);
			case TMap(key, value): session.requiresSpecializedMap(key,
					value) || usesSpecializedMap(session, key, explored) || usesSpecializedMap(session, value, explored);
			case TKeyPath(root, value, _): usesSpecializedMap(session, root, explored) || usesSpecializedMap(session, value, explored);
			case TFunction(arguments, result): anyUsesSpecializedMap(session, arguments, explored) || usesSpecializedMap(session, result, explored);
			case TAnonymous(_, fields):
				if (explored.indexOf(fields) >= 0) false else {
					explored.push(fields);
					var found = anyUsesSpecializedMap(session, [for (field in fields) field.type], explored);
					explored.pop();
					found;
				}
			default: false;
		};

	static function anyUsesSpecializedMap(session:TypingSession, types:Array<CompilerType>, explored:Array<Array<AnonymousField>>):Bool {
		for (type in types)
			if (usesSpecializedMap(session, type, explored))
				return true;
		return false;
	}
}
