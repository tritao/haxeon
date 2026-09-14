package compiler.types.typing;

import compiler.semantic.SemanticProgram;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;
import compiler.syntax.Ast.AstFunction;
import compiler.types.typing.TypingMetrics.MeasuredTypedProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.NativeConvention;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.analysis.Scope;

/** Coordinates the program-level typing phases and their lifecycle transitions. */
class ProgramTyper {
	final bodyTyper:BodyTyper;
	final session:TypingSession;
	final externTyper:ExternTyper;
	final assembler:TypedProgramAssembler;

	public function new(bodyTyper:BodyTyper) {
		this.bodyTyper = bodyTyper;
		this.session = bodyTyper.session;
		this.externTyper = new ExternTyper(argument -> bodyTyper.argumentType(argument), type -> bodyTyper.lowerType(type));
		this.assembler = new TypedProgramAssembler(session, function(type) bodyTyper.registerAnonymousTypes(type));
	}

	public function typeProgramMeasured(semantic:SemanticProgram, selected:Null<Map<String, Bool>>, requireMain:Bool,
			entryPoint:Null<String>):MeasuredTypedProgram {
		var startedAt = Sys.time() * 1000.0;
		semantic.lifecycle.requireAtLeast(SignatureTyped);
		session.bindSemantic(semantic);
		var program = semantic.program;
		for (decl in program.enumAbstracts) {
			var emptySubstitutions:Map<String, CompilerType> = [];
			var underlying = session.declarations.resolve(decl.underlying, null, emptySubstitutions);
			for (value in decl.values)
				bodyTyper.coerce(bodyTyper.typeExpression(value.value, new Scope(), underlying), underlying,
					'enum abstract value "${decl.name}.${value.name}"', "E1002");
		}
		session.bindNominalDeclarations();
		for (alias in program.aliases) {
			if (alias.typeParameters.length == 0) {
				var aliasType = bodyTyper.lowerType(alias.type);
				bodyTyper.registerAnonymousTypes(aliasType);
			}
		}
		var typedNatives:Array<TypedNative> = [];
		for (fn in program.functions) {
			if (session.externals.exists(fn.name))
				BodyTyper.fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
			if (fn.isExtern == true)
				typedNatives.push(externTyper.typeExtern(fn));
		}
		for (classDecl in program.classes) {
			var defaultLibrary = externTyper.nativeLibrary(classDecl.name, classDecl.metadata);
			if (classDecl.isExtern == true || defaultLibrary != null) {
				for (method in classDecl.methods) {
					if (!method.isStatic)
						BodyTyper.fail("E1021", 'Extern instance method "${classDecl.name}.${method.name}" is not supported yet', method.span);
					var nativeName = method.name.indexOf(".") >= 0 ? method.name : classDecl.name + "." + method.name;
					typedNatives.push(externTyper.typeExtern(method, nativeName, null, defaultLibrary, null, defaultLibrary != null));
				}
			}
		}
		for (abstractDecl in program.abstracts)
			if (abstractDecl.isExtern == true) {
				var defaultLibrary = externTyper.nativeLibrary(abstractDecl.name, abstractDecl.metadata);
				for (method in abstractDecl.methods) {
					var nativeName = method.name.indexOf(".") >= 0 ? method.name : abstractDecl.name + "." + method.name;
					var receiverType = method.isStatic
						|| method.name == "new" ? null : session.declarations.resolve(abstractDecl.underlying, abstractDecl.span,
							BodyTyper.declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters));
					var resultOverride = method.name == "new" ? session.declarations.resolve(abstractDecl.underlying, abstractDecl.span,
						BodyTyper.declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters)) : null;
					typedNatives.push(externTyper.typeExtern(method, nativeName, receiverType, defaultLibrary, resultOverride));
				}
			}
		for (native in typedNatives)
			switch native.convention {
				case CNative(_):
					session.cNativeFunctions.set(native.name, true);
				case HashLinkNative:
			}
		var setupDoneAt = Sys.time() * 1000.0;
		bodyTyper.inferNoReturnFunctions();
		var noReturnDoneAt = Sys.time() * 1000.0;
		if (requireMain) {
			var main:AstFunction;
			if (entryPoint != null && session.signatures.exists(entryPoint))
				main = BodyTyper.requiredMapValue(session.signatures, entryPoint);
			else if (entryPoint == null && session.signatures.exists("main"))
				main = BodyTyper.requiredMapValue(session.signatures, "main");
			else if (entryPoint == null && session.signatures.exists("Main.main"))
				main = BodyTyper.requiredMapValue(session.signatures, "Main.main");
			else
				throw 'Program must define executable entry point "${entryPoint == null ? "main" : entryPoint}"';
			if (main.arguments.length != 0 || (bodyTyper.lowerType(main.result) != TInt && bodyTyper.lowerType(main.result) != TVoid))
				throw 'Executable entry point "${entryPoint == null ? main.name : entryPoint}" must take no arguments and return Int or Void';
		}
		var typedEnums:Array<TypedEnum> = [
			for (enumDecl in program.enums)
				{
					name: enumDecl.name,
					cases: [
						for (caseDecl in enumDecl.cases)
							{
								name: caseDecl.name,
								params: [for (param in caseDecl.params) bodyTyper.erasedEnumParameter(enumDecl, param)],
								span: caseDecl.span
							}
					],
					span: enumDecl.span
				}
		], typedInterfaces:Array<TypedInterface> = [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: [for (base in interfaceDecl.bases) BodyTyper.inheritanceName(base)],
					methods: [
						for (method in interfaceDecl.methods)
							{
								name: method.name,
								arguments: [
									for (argument in method.arguments)
										bodyTyper.erasedInterfaceType(interfaceDecl, argument.type, argument.span)
								],
								result: bodyTyper.erasedInterfaceType(interfaceDecl, method.result, method.span)
							}
					]
				}
			], typedClasses:Array<TypedClass> = [
			for (classDecl in program.classes)
				if (classDecl.isExtern != true
					&& externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null) bodyTyper.typeClass(classDecl, session.classDecls, selected)
			], typedFunctions:Array<TypedFunction> = [];
		var metadataDoneAt = Sys.time() * 1000.0;
		for (fn in program.functions)
			if (fn.isExtern != true && !BodyTyper.isGeneric(fn) && (selected == null || selected.exists(fn.name)))
				typedFunctions.push(bodyTyper.typeFunction(fn));
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		for (abstractDecl in program.abstracts)
			for (method in abstractDecl.methods) {
				var name = abstractDecl.name + "." + method.name;
				if (abstractDecl.isExtern != true
					&& method.isStatic
					&& !BodyTyper.isGeneric(BodyTyper.requiredMapValue(session.signatures, name))
					&& (selected == null || selected.exists(name)))
					typedFunctions.push(bodyTyper.typeFunction(BodyTyper.requiredMapValue(session.signatures, name), abstractDecl.name, true));
			}
		for (lambda in session.closureConversion.generatedFunctions())
			typedFunctions.push(lambda);
		assembler.registerProgramTypes(typedFunctions, typedClasses, typedInterfaces, typedEnums, typedNatives);
		var bodiesDoneAt = Sys.time() * 1000.0;
		semantic.lifecycle.advanceAll(BodyTyped);
		var bodyTransitionDoneAt = Sys.time() * 1000.0;
		var result:TypedProgram = assembler.assemble(typedEnums, typedInterfaces, typedClasses, typedFunctions, typedNatives);
		var assemblyDoneAt = Sys.time() * 1000.0;
		semantic.lifecycle.advanceAll(Finalized);
		var finalizationDoneAt = Sys.time() * 1000.0;
		var typedRuntimeDependencies = assembler.runtimeDependencies();
		return {
			program: result,
			runtimeDependencies: typedRuntimeDependencies,
			metrics: {
				declarationMs: semantic.lifecycleMetrics.declarationMs,
				shapeConnectionMs: semantic.lifecycleMetrics.shapeConnectionMs,
				signatureTypingMs: semantic.lifecycleMetrics.signatureTypingMs,
				setupMs: setupDoneAt - startedAt,
				noReturnMs: noReturnDoneAt - setupDoneAt,
				metadataMs: metadataDoneAt - noReturnDoneAt,
				bodiesMs: bodiesDoneAt - metadataDoneAt,
				bodyTransitionMs: bodyTransitionDoneAt - bodiesDoneAt,
				assemblyMs: assemblyDoneAt - bodyTransitionDoneAt,
				finalizationMs: finalizationDoneAt - assemblyDoneAt
			}
		};
	}
}
