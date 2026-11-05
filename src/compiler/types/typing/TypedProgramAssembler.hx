package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedClass;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;

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
		function register(type:CompilerType, ?origin:String):Void {
			registerAnonymousType(type);
			session.representation.discoverGenericOwners(type, origin);
		}
		for (fn in functions) {
			for (argument in fn.arguments)
				register(argument.type, fn.name);
			register(fn.result, fn.name);
		}
		for (classDecl in classes) {
			// A struct can reach Dynamic through reflection or a shape-erased generic
			// owner, without any source-level conversion naming its concrete type.
			// Register its declared conformance with its runtime type, independently
			// of which escape the source happened to use. Unused helpers are pruned.
			var origin = classDecl.methods.length > 0 ? classDecl.methods[0].name : functions.length > 0 ? functions[0].name : null;
			if (classDecl.isValue && !classDecl.isNativeValue && origin != null) {
				var type = TInstance(NominalKind.Class, classDecl.specializationOrigin == null ? classDecl.name : classDecl.specializationOrigin,
					classDecl.specializationArguments == null ? [] : classDecl.specializationArguments);
				if (!session.representation.containsTypeParameter(type, []) && DeclaredConformance.has(session, type, "Equatable"))
					ValueEqualityGenerator.request(session, type, origin, classDecl.span);
			}
			for (field in classDecl.fields)
				register(field.type, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX +
					(classDecl.specializationOrigin == null ? classDecl.name : classDecl.specializationOrigin));
		}
		for (interfaceDecl in interfaces)
			for (method in interfaceDecl.methods) {
				for (argument in method.arguments)
					register(argument, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + interfaceDecl.name);
				register(method.result, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + interfaceDecl.name);
			}
		for (enumDecl in enums)
			for (enumCase in enumDecl.cases)
				for (parameter in enumCase.params)
					register(parameter, RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX + enumDecl.name);
		for (native in natives) {
			for (argument in native.arguments)
				register(argument);
			register(native.result);
		}
	}

	public function assemble(enums:Array<TypedEnum>, interfaces:Array<TypedInterface>, classes:Array<TypedClass>, functions:Array<TypedFunction>,
			natives:Array<TypedNative>, nativeTypeDescriptors:Array<NativeTypeDescriptorData>):TypedProgram {
		return {
			nativeAbiTarget: session.nativeAbiTarget,
			genericOwnerAliases: session.representation.genericOwnerAliases(),
			nativeTypeDescriptors: nativeTypeDescriptors,
			enums: enums,
			interfaces: interfaces,
			classes: classes,
			functions: functions,
			closurePlan: session.closureConversion.plan(),
			anonymousTypes: orderedAnonymousTypes(),
			natives: natives
		};
	}

	public function runtimeDependencies():Array<{var functionName:String; var target:String;}>
		return session.runtimeDependencyTracker.ordered();

	function orderedAnonymousTypes():Array<compiler.types.TypedAst.TypedAnonymous> {
		var names = [for (name in session.anonymousTypes.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {name: name, fields: session.anonymousTypes.get(name)}];
	}
}
