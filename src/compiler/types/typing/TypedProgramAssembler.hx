package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedClass;

typedef AnonymousTypeRegistrar = CompilerType->Void;

/** Registers final anonymous types and assembles the typed program value. */
class TypedProgramAssembler {
	final session:TypingSession;
	final registerAnonymousType:AnonymousTypeRegistrar;

	public function new(session:TypingSession, registerAnonymousType:AnonymousTypeRegistrar) {
		this.session = session;
		this.registerAnonymousType = registerAnonymousType;
	}

	public function registerProgramTypes(functions:Array<TypedFunction>, classes:Array<TypedClass>, interfaces:Array<TypedInterface>, enums:Array<TypedEnum>,
			natives:Array<TypedNative>):Void {
		for (fn in functions) {
			for (argument in fn.arguments)
				registerAnonymousType(argument.type);
			registerAnonymousType(fn.result);
		}
		for (classDecl in classes)
			for (field in classDecl.fields)
				registerAnonymousType(field.type);
		for (interfaceDecl in interfaces)
			for (method in interfaceDecl.methods) {
				for (argument in method.arguments)
					registerAnonymousType(argument);
				registerAnonymousType(method.result);
			}
		for (enumDecl in enums)
			for (enumCase in enumDecl.cases)
				for (parameter in enumCase.params)
					registerAnonymousType(parameter);
		for (native in natives) {
			for (argument in native.arguments)
				registerAnonymousType(argument);
			registerAnonymousType(native.result);
		}
	}

	public function assemble(enums:Array<TypedEnum>, interfaces:Array<TypedInterface>, classes:Array<TypedClass>, functions:Array<TypedFunction>,
			natives:Array<TypedNative>):TypedProgram {
		return {
			enums: enums,
			interfaces: interfaces,
			classes: classes,
			functions: functions,
			closurePlan: session.closureConversion.plan(),
			anonymousTypes: orderedAnonymousTypes(),
			natives: natives
		};
	}

	public function runtimeDependencies():Array<{final functionName:String; final target:String;}> {
		var dependencies = [
			for (functionName => targets in session.runtimeDependencies)
				for (target in targets.keys())
					{functionName: functionName, target: target}
		];
		dependencies.sort(function(left, right) {
			var functionOrder = Reflect.compare(left.functionName, right.functionName);
			return functionOrder == 0 ? Reflect.compare(left.target, right.target) : functionOrder;
		});
		return dependencies;
	}

	function orderedAnonymousTypes():Array<compiler.types.TypedAst.TypedAnonymous> {
		var names = [for (name in session.anonymousTypes.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {name: name, fields: session.anonymousTypes.get(name)}];
	}
}
