package compiler.types.typing;

import compiler.core.AllocationMeter;
import compiler.core.Diagnostic;
import compiler.core.DiagnosticCode;
import compiler.core.UnresolvedNameKind;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.NativeLayout;
import compiler.runtime.RuntimeType;
import compiler.runtime.RuntimeType;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;
import compiler.semantic.InitializerUnit;
import compiler.semantic.InterfaceFieldAccessors;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.AstFunctions;
import compiler.syntax.AstPredicates;
import compiler.types.DeclarationIndex;
import compiler.types.StructProperties;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.NativeConvention;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedFunctionRole;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedNativeLayout;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.AbstractConstructorNormalizer;
import compiler.types.analysis.Scope;
import compiler.types.typing.TypingMetrics.MeasuredTypedProgram;

/**
 * What a warm build takes of the declarations from the session: each module's declaration keys, and the signatures of unannotated
 * functions an earlier build typed (`ModuleState.inferredSignatures`), which it gives the functions it does not type again
 * (`DeclarationTypeTable.seedFunctions`). With `check` (`--check-reuse`), the keys are compared with keys made from the whole
 * program, and each seeded signature is typed again on its first read and compared.
 */
typedef KeptDeclarations = {
	/** The declaration keys the session keeps for each module of the program (`SessionState.declarationKeys`). */
	final moduleKeys:Array<DeclarationKeys.ModuleDeclarationKeys>;

	/** The signature an earlier build gave the unannotated function of a key, which a function this build does not type keeps. */
	final signature:String->Null<compiler.types.DeclarationTypes.InferredSignature>;

	/** `--check-reuse`: what is kept is compared with what this build makes afresh. */
	final check:Bool;
}

/** Coordinates the program-level typing phases and their lifecycle transitions. */
class ProgramTyper implements DeclarationTypeTable.DeclarationTyping {
	final bodyTyper:BodyTyper;
	final session:TypingSession;
	final externTyper:ExternTyper;
	final assembler:TypedProgramAssembler;

	/** Type bodies and field initializers last declared first; see `CompileOptions.reverseTypingOrder`. */
	final reverseTypingOrder:Bool;

	/** The bodies the program being typed types again (null: all), which `typeInferredFunction` keeps for their slots. */
	var selectedBodies:Null<Map<String, Bool>> = null;

	/** Make a generic class's erased code by elaborating its own-parameter typing; see `CompileOptions.elaborateGenerics`. */
	final elaborateGenerics:Bool;

	public function new(bodyTyper:BodyTyper, reverseTypingOrder:Bool = false, elaborateGenerics:Bool = false,
			?nullSafety:Array<compiler.NullSafetyRule>) {
		this.bodyTyper = bodyTyper;
		if (nullSafety != null)
			bodyTyper.session.nullSafety.rules = nullSafety;
		this.reverseTypingOrder = reverseTypingOrder;
		this.elaborateGenerics = elaborateGenerics;
		bodyTyper.genericInstantiation.elaborateGenerics = elaborateGenerics;
		this.session = bodyTyper.session;
		this.externTyper = new ExternTyper(fn -> bodyTyper.argumentTypesOf(fn),
			(type, span) -> bodyTyper.lowerType(type, span));
		this.assembler = new TypedProgramAssembler(session, function(type) bodyTyper.registerAnonymousTypes(type));
	}

	/**
	 * Types the program. A body (a function, a field initializer) whose typing fails is recorded and left out, and the other bodies are
	 * typed; the program then fails with every recorded error, before anything is generated from the bodies. An error outside the
	 * bodies (a declaration, a generated helper) stops typing where it is met, with the errors recorded before it.
	 */
	public function typeProgramMeasured(semantic:SemanticProgram, selected:Null<Map<String, Bool>>, requireMain:Bool,
			entryPoint:Null<String>,
			?cachedMetadata:TypedProgram, ?facts:compiler.semantic.ProgramFacts,
			?retained:RetainedFromPrevious, ?kept:KeptDeclarations,
			?entrySpan:SourceSpan):MeasuredTypedProgram {
		try {
			var typed = typeProgramPhases(semantic, selected, requireMain, entryPoint, cachedMetadata, facts, retained,
				kept, entrySpan);
			session.failIfRecovered([]);
			return typed;
		} catch (error:CompileError) {
			// The declarations the table belongs to are shared with the programs kept before, which would keep it.
			var types = session.types;
			if (types != null)
				types.endTyping();
			// A failure after the bodies were typed carries them already; any other comes with the errors recovered before it.
			if (Std.isOfType(error, TypingFailure))
				throw error;
			throw session.withRecovered(error);
		}
	}

	function typeProgramPhases(semantic:SemanticProgram, selected:Null<Map<String, Bool>>, requireMain:Bool,
			entryPoint:Null<String>, cachedMetadata:Null<TypedProgram>, facts:Null<compiler.semantic.ProgramFacts>,
			retained:Null<RetainedFromPrevious>, kept:Null<KeptDeclarations>,
			entrySpan:Null<SourceSpan>):MeasuredTypedProgram {
		var allocationAtStart = AllocationMeter.sample();
		var startedAt = Sys.time() * 1000.0;
		semantic.lifecycle.requireAtLeast(SignatureTyped);
		selectedBodies = selected;
		session.keptHelpers = retained == null ? null : retained.helpers;
		session.bindSemantic(semantic, bodyTyper.defaultValueType, this, kept == null ? null : kept.moduleKeys,
			kept != null && kept.check);
		if (kept != null && selected != null)
			requiredTypes().seedFunctions(kept.signature, selected, kept.check);
		var refreshing:Map<String, Bool> = [];
		if (cachedMetadata != null) {
			bindCachedNativeLayouts(cachedMetadata.classes);
			refreshing = classesToRefresh(semantic.program.classes, cachedMetadata.classes, selected);
		}
		var program = semantic.program;
		// An enum abstract value may call a class's static, as a constant that is not one does before it is rejected.
		session.bindNominalDeclarations();
		for (decl in session.declarations.enumAbstractsInOrder()) {
			RawEnumGenerator.validate(session, bodyTyper, decl);
			FlagsGenerator.validate(session, bodyTyper, decl);
			for (value in decl.values)
				EnumAbstractValues.raw(bodyTyper, decl, value);
		}
		// With the facts of `SemanticAssembly` there is nothing to infer: they are about this same program. They are known before
		// anything reads a field's type, which can type its initializer (`DeclarationTypeTable`).
		if (facts == null) {
			bodyTyper.declareNoReturnFunctions();
			session.inferPureFunctions();
		} else {
			bodyTyper.useNoReturnFunctions(facts.noReturn);
			session.usePureFunctions(facts.pure);
		}
		for (declaration in program.enums)
			validateEnumConformance(declaration);
		bodyTyper.expressionTyper.prepareNativeTypeAnnotations(program);
		for (alias in program.aliases) {
			if (alias.typeParameters.length == 0) {
				var aliasType = bodyTyper.lowerType(alias.type, alias.span);
				bodyTyper.registerAnonymousTypes(aliasType);
			}
		}
		var typedNatives:Array<TypedNative> = cachedMetadata == null ? [] : cachedMetadata.natives;
		if (cachedMetadata == null)
			for (fn in program.functions) {
				if (session.externals.exists(fn.name))
					BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
						'Function "${fn.name}" conflicts with a registered native', fn.span);
				if (fn.isExtern == true)
					typedNatives.push(externTyper.typeExtern(fn));
			}
		if (cachedMetadata == null)
			for (classDecl in program.classes) {
				var defaultLibrary = externTyper.nativeLibrary(classDecl.name, classDecl.metadata),
					externClass = classDecl.isExtern == true || defaultLibrary != null;
				// An extern class's methods are natives, and so is an `extern` method without a body in any other class.
				for (method in classDecl.methods)
					if (externClass || method.isExtern == true) {
						if (!method.isStatic)
							BodyTyper.fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
								'Extern instance method "${classDecl.name}.${method.name}" is not supported yet',
								method.span);
						var nativeName = method.name.indexOf(".") >= 0
							? method.name : classDecl.name + "." + method.name;
						typedNatives.push(externTyper.typeExtern(method, nativeName, null, defaultLibrary, null,
							defaultLibrary != null));
					}
			}
		if (cachedMetadata == null)
			for (abstractDecl in program.abstracts) {
				var defaultLibrary = abstractDecl.isExtern == true ? externTyper.nativeLibrary(abstractDecl.name,
					abstractDecl.metadata) : null;
				for (method in abstractDecl.methods)
					if (abstractDecl.isExtern == true || method.isExtern == true) {
						var nativeName = method.name.indexOf(".") >= 0
							? method.name : abstractDecl.name + "." + method.name;
						var receiverType = method.isStatic
							|| method.name == "new" ? null : session.declarations.resolve(abstractDecl.underlying,
							abstractDecl.span,
							BodyTyper.declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters));
						var resultOverride = method.name == "new"
							? session.declarations.resolve(abstractDecl.underlying, abstractDecl.span,
							BodyTyper.declarationTypeSubstitutions(abstractDecl.name, abstractDecl.typeParameters))
							: null;
						typedNatives.push(externTyper.typeExtern(method, nativeName, receiverType, defaultLibrary,
							resultOverride));
					}
			}
		if (cachedMetadata == null) {
			// A C native binding replaces a function's body, so only an extern function can carry one; on any other function the
			// body would silently run instead of the native. (`@:hlNative` with a body binds the native, as in Haxe.)
			for (fn in program.functions)
				if (fn.isExtern != true)
					rejectNativeBinding(fn, fn.name);
			for (classDecl in program.classes)
				if (classDecl.isExtern != true && externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null)
					for (method in classDecl.methods)
						if (method.isExtern != true)
							rejectNativeBinding(method, classDecl.name + "." + method.name);
			for (abstractDecl in program.abstracts)
				if (abstractDecl.isExtern != true)
					for (method in abstractDecl.methods)
						if (method.isExtern != true)
							rejectNativeBinding(method, abstractDecl.name + "." + method.name);
			for (abstractDecl in program.abstracts)
				AbstractProperties.validate(session, abstractDecl);
			for (interfaceDecl in program.interfaces)
				InterfaceProperties.validate(interfaceDecl);
			for (classDecl in program.classes)
				if (classDecl.isExtern != true)
					ClassProperties.validate(session, classDecl);
		}
		for (native in typedNatives)
			switch native.convention {
				case CNative(_):
					session.cNativeFunctions.set(native.name, true);
				case HashLinkNative:
			}
		var setupDoneAt = Sys.time() * 1000.0;
		var allocationAfterSetup = AllocationMeter.sample();
		bodyTyper.checkNoReturnOverrides();
		var noReturnDoneAt = Sys.time() * 1000.0;
		var allocationAfterNoReturn = AllocationMeter.sample();
		// Body typing reads native layouts, and an unannotated declaration's body is typed as soon as its type is first needed.
		if (cachedMetadata == null)
			prepareNativeLayouts(program.classes);
		if (requireMain) {
			var main:AstFunction;
			if (entryPoint != null && session.signatures.exists(entryPoint))
				main = session.signatures.required(entryPoint);
			else if (entryPoint == null && session.signatures.exists("main"))
				main = session.signatures.required("main");
			else if (entryPoint == null && session.signatures.exists("Main.main"))
				main = session.signatures.required("Main.main");
			else
				throw new CompileError(new compiler.core.Diagnostic(DiagnosticCode.DECLARATION_CONFLICT,
					'Program must define executable entry point "${entryPoint == null ? "main" : entryPoint}"',
					entrySpan ?? session.declarations.fallbackSpan));
			var result = main.arguments.length == 0 ? bodyTyper.functionResultType(main, main.span) : TVoid,
				returnsIntOrVoid = switch result {
					case TInt, TVoid: true;
					default: false;
				};
			// An unannotated entry point whose body failed has no result type: its body's error is the one to report.
			var bodyFailed = AstFunctions.isInferred(main.result) && session.recoveredErrors.length > 0;
			if (main.arguments.length != 0 || !returnsIntOrVoid && !bodyFailed)
				throw new CompileError(new compiler.core.Diagnostic(DiagnosticCode.DECLARATION_CONFLICT,
					'Executable entry point "${entryPoint == null ? main.name : entryPoint}" must take no arguments and return Int or Void',
					main.span));
		}
		var typedEnums:Array<TypedEnum> = cachedMetadata == null ? [for (enumDecl in program.enums)
			{
				name: enumDecl.name,
				isRecursive: session.enumRepresentations.isRecursive(enumDecl.name),
				equatable: DeclaredConformance.has(session, TInstance(NominalKind.Enum, enumDecl.name, []),
					"Equatable"),
				hashable: DeclaredConformance.has(session, TInstance(NominalKind.Enum, enumDecl.name, []),
					"Hashable"),
				metadata: enumDecl.metadata,
				cases: [for (caseDecl in enumDecl.cases)
					{
						name: caseDecl.name,
						metadata: caseDecl.metadata,
						params: [
							for (param in caseDecl.params)
								session.representation.enumStorageType(enumDecl.typeParameters, param,
								TInstance(NominalKind.Enum, enumDecl.name, []))
						],
						span: caseDecl.span
					}],
				span: enumDecl.span
			}] : [
				for (declaration in cachedMetadata.enums)
					if (declaration.specializationOrigin == null) declaration
			],
			typedInterfaces:Array<TypedInterface> = cachedMetadata == null
				? [for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: [
						for (base in interfaceDecl.bases)
							if (!StructProperties.isConstraintSyntax(base)) BodyTyper.inheritanceName(base)
					],
					methods: [for (method in interfaceDecl.methods) if (method.isDynamic != true)
						{
							name: method.name,
							arguments: [
								for (argument in method.arguments)
									session.representation.resolveMethodArgument(TInstance(NominalKind.Interface,
									interfaceDecl.name,
									[for (_ in interfaceDecl.typeParameters) TDynamic]),
									interfaceDecl.name, argument)
									.physical
							],
							result: erasureType(interfaceDecl, method.result, method.span)
						}]
				}] : cachedMetadata.interfaces,
			typedClasses:Array<TypedClass> = cachedMetadata == null
				? typeDeclaredClasses(program.classes, selected) : refreshCachedClasses(program.classes,
				cachedMetadata.classes, selected, refreshing),
			typedFunctions:Array<TypedFunction> = [];
		// Unchanged code keeps the generic owners and generated classes it uses, whether or not the declaration metadata of the
		// previous program is reused. Owners are asked for again and typed from the current declarations, so a program that
		// gained or changed declarations still has every owner its unchanged callers refer to. With reused metadata the
		// generated classes are already among the cached ones.
		if (retained != null) {
			var carried = takeFromPrevious(retained);
			if (cachedMetadata == null)
				typedClasses = typedClasses.concat(carried);
		}
		if (cachedMetadata != null)
			typedClasses = [for (cached in typedClasses) if (cached.specializationOrigin == null) cached];
		if (cachedMetadata == null)
			for (enumDecl in typedEnums)
				for (caseDecl in enumDecl.cases)
					for (parameter in caseDecl.params)
						if (NativeLayout.containsNativeLayoutType(parameter))
							BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
								'Native layout types cannot be stored in a Haxe enum yet',
								caseDecl.span);
		if (cachedMetadata == null)
			for (interfaceIndex in 0...typedInterfaces.length) {
				var interfaceDecl = typedInterfaces[interfaceIndex],
					parsedMethods = [for (method in program.interfaces[interfaceIndex].methods) if (method.isDynamic
						!= true) method];
				for (methodIndex in 0...interfaceDecl.methods.length) {
					var method = interfaceDecl.methods[methodIndex],
						parsedMethod = parsedMethods[methodIndex];
					for (argument in method.arguments)
						if (NativeLayout.containsNativeLayoutType(argument))
							BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
								'Native layout types cannot be passed by value in an interface yet',
								parsedMethod.span);
					if (NativeLayout.containsNativeLayoutType(method.result))
						BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
							'Native layout types cannot be returned by value in an interface yet',
							parsedMethod.span);
				}
			}
		if (cachedMetadata == null)
			typedClasses = layoutNativeClasses(typedClasses);
		else
			bindCachedNativeLayouts(typedClasses);
		var metadataDoneAt = Sys.time() * 1000.0;
		var allocationAfterMetadata = AllocationMeter.sample();
		// Each body is a unit typed into its own output; the outputs are merged in declaration order once all are typed.
		// Reversed, the three groups of bodies are typed last first as well as each group's bodies.
		var moduleFunctions:Array<TypedFunction> = [],
			abstractFunctions:Array<TypedFunction> = [],
			classUnits:Array<TypingOutput> = [],
			functionUnits:Array<TypingOutput> = [],
			abstractUnits:Array<TypingOutput> = [];
		if (reverseTypingOrder) {
			abstractFunctions = typeAbstractFunctions(program.abstracts, selected, abstractUnits);
			moduleFunctions = typeModuleFunctions(program.functions, selected, functionUnits);
		}
		if (cachedMetadata == null)
			typedClasses = typeClassBodies(program.classes, typedClasses, selected, classUnits);
		var classBodiesDoneAt = Sys.time() * 1000.0;
		var allocationAfterClassBodies = AllocationMeter.sample();
		if (!reverseTypingOrder) {
			moduleFunctions = typeModuleFunctions(program.functions, selected, functionUnits);
			abstractFunctions = typeAbstractFunctions(program.abstracts, selected, abstractUnits);
		}
		checkNativeBoundBodies(program, selected);
		session.mergeUnits(classUnits.concat(functionUnits).concat(abstractUnits));
		for (fn in moduleFunctions)
			typedFunctions.push(fn);
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		for (fn in abstractFunctions)
			typedFunctions.push(fn);
		// What the bodies ask for is generated next: not from a program some of whose bodies failed. The ones that typed go with
		// the failure, with the lambdas and specializations they made, for the editor.
		if (session.recoveredErrors.length > 0) {
			var conversion = session.programOutput.closureConversion;
			session.failIfRecovered(typedFunctions.concat([
				for (index in 0...conversion.generatedFunctionCount())
					conversion.generatedFunction(index)
			]));
		}
		var functionBodiesDoneAt = Sys.time() * 1000.0;
		var allocationAfterFunctionBodies = AllocationMeter.sample();
		// Field and signature types can request owners without a construction expression. A
		// generated owner's fields and methods can request further owners, so drain to a fixed point.
		assembler.registerProgramTypes(typedFunctions, typedClasses, typedInterfaces, typedEnums, typedNatives);
		var ownerDeclarations = [for (declaration in program.classes) declaration.name => declaration],
			ownerIndex = 0,
			generatedIndex = 0,
			pathClassIndex = 0,
			enumIndex = 0;
		var keyPaths = new KeyPathRuntime(session, typedClasses);
		function drainRuntimeTypes():Void
			while (true) {
				while (enumIndex < session.enumRepresentations.count()) {
					var declaration = session.enumRepresentations.declaration(enumIndex++);
					typedEnums.push(declaration);
					assembler.registerProgramTypes([], [], [], [declaration], []);
				}
				var pathHelpers = keyPaths.drain();
				for (helper in pathHelpers)
					typedFunctions.push(helper);
				if (pathHelpers.length > 0)
					assembler.registerProgramTypes(pathHelpers, [], [], [], []);
				while (pathClassIndex < keyPaths.newClasses.length) {
					var cache = keyPaths.newClasses[pathClassIndex++];
					typedClasses.push(cache);
					assembler.registerProgramTypes([], [cache], [], [], []);
				}
				while (generatedIndex < session.programOutput.closureConversion.generatedFunctionCount()) {
					var fn = session.programOutput.closureConversion.generatedFunction(generatedIndex++);
					typedFunctions.push(fn);
					assembler.registerProgramTypes([fn], [], [], [], []);
				}
				if (enumIndex < session.enumRepresentations.count())
					continue;
				if (ownerIndex >= session.representation.genericOwnerRequestCount())
					break;
				var request = session.representation.genericOwnerRequest(ownerIndex++),
					declaration = ownerDeclarations.get(request.origin);
				if (declaration == null)
					throw new InternalError('Missing generic owner declaration "${request.origin}"');
				var specialized = typeClass(declaration, null, false, request);
				typedClasses.push(specialized);
				for (method in specialized.methods)
					typedFunctions.push(method);
				assembler.registerProgramTypes(specialized.methods, [specialized], [], [], []);
			}
		drainRuntimeTypes();
		// Reflection can expose a field as Dynamic without a source-level enum conversion.
		// Keep the concrete enum operations available for those raw runtime descriptors.
		var reflectedClassIndex = 0;
		function requestFieldReflection(classDecl:TypedClass):Void {
			var origin = classDecl.methods.length > 0 ? classDecl.methods[0].name : typedFunctions.length > 0
				? typedFunctions[0].name : null;
			if (origin != null)
				for (field in classDecl.fields)
					EnumDynamicBox.requestReflectedTypes(session, field.type, origin, field.span);
		}
		function reflectNewClasses():Void {
			while (reflectedClassIndex < typedClasses.length)
				requestFieldReflection(typedClasses[reflectedClassIndex++]);
		}
		// Native signatures can expose a typed enum (including a container element) as Dynamic.
		if (typedFunctions.length > 0)
			for (native in typedNatives) {
				var owner = typedFunctions[0];
				for (argument in native.arguments)
					EnumDynamicBox.requestReflectedTypes(session, argument, owner.name, owner.span);
				EnumDynamicBox.requestReflectedTypes(session, native.result, owner.name, owner.span);
			}
		// Generated bodies can request owners, closures, paths and further helpers. Complete
		// them together; a helper is not finished merely because its own request map is stable.
		var equalities:Map<String, TypedFunction> = [],
			hashes:Map<String, TypedFunction> = [],
			enumMethods:Map<String, TypedFunction> = [],
			enumAdapters:Map<String, TypedClass> = [],
			codecs:Map<String, TypedFunction> = [],
			rawMethods:Map<String, TypedFunction> = [],
			flagMethods:Map<String, TypedFunction> = [],
			dynamicStructures:Map<String, TypedFunction> = [];
		function requestCount():Int
			return session.programOutput.requests.count() + Lambda.count(session.keyPaths.definitions)
				+ session.representation.genericOwnerRequestCount()
				+ session.programOutput.closureConversion.generatedFunctionCount()
				+ session.enumRepresentations.count();
		while (true) {
			drainRuntimeTypes();
			reflectNewClasses();
			var before = requestCount();
			for (method in FlagsGenerator.generate(session, bodyTyper, flagMethods))
				assembler.registerProgramTypes([method], [], [], [], []);
			for (method in RawEnumGenerator.generate(session, bodyTyper, rawMethods))
				assembler.registerProgramTypes([method], [], [], [], []);
			for (codec in WireCodecGenerator.generate(session, typedClasses, typedEnums)
				.concat(WireCodecGenerator.generateJson(session, typedClasses, typedEnums))) {
				codecs.set(codec.name, codec);
				assembler.registerProgramTypes([codec], [], [], [], []);
			}
			for (adapter in EnumInterfaceAdapter.generate(session)) {
				enumAdapters.set(adapter.name, adapter);
				requestFieldReflection(adapter);
				assembler.registerProgramTypes(adapter.methods, [adapter], [], [], []);
			}
			for (hash in HashGenerator.generate(session, bodyTyper)) {
				hashes.set(hash.name, hash);
				assembler.registerProgramTypes([hash], [], [], [], []);
			}
			for (equality in ValueEqualityGenerator.generate(session, bodyTyper.expressionTyper.compareKnownValues)) {
				equalities.set(equality.name, equality);
				assembler.registerProgramTypes([equality], [], [], [], []);
			}
			for (equality in EnumEqualityGenerator.generate(session, bodyTyper)) {
				equalities.set(equality.name, equality);
				assembler.registerProgramTypes([equality], [], [], [], []);
			}
			for (method in EnumConformanceMethods.generate(session, bodyTyper)) {
				enumMethods.set(method.name, method);
				assembler.registerProgramTypes([method], [], [], [], []);
			}
			for (copy in bodyTyper.generateDynamicStructures(dynamicStructures))
				assembler.registerProgramTypes([copy], [], [], [], []);
			drainRuntimeTypes();
			reflectNewClasses();
			if (before == requestCount())
				break;
		}
		var flagNames = [for (name in flagMethods.keys()) name];
		flagNames.sort(Reflect.compare);
		for (name in flagNames)
			typedFunctions.push(flagMethods.get(name));
		var rawNames = [for (name in rawMethods.keys()) name];
		rawNames.sort(Reflect.compare);
		for (name in rawNames)
			typedFunctions.push(rawMethods.get(name));
		var codecNames = [for (name in codecs.keys()) name];
		codecNames.sort(Reflect.compare);
		for (name in codecNames)
			typedFunctions.push(codecs.get(name));
		var adapterNames = [for (name in enumAdapters.keys()) name];
		adapterNames.sort(Reflect.compare);
		// An adapter the code typed again asked for again replaces the one carried from the previous program
		// (`takeFromPrevious`), so the program lists it once, where a fresh build lists it.
		var position = typedClasses.length;
		while (position-- > 0)
			if (enumAdapters.exists(typedClasses[position].name))
				typedClasses.splice(position, 1);
		for (name in adapterNames) {
			var adapter = enumAdapters.get(name);
			typedClasses.push(adapter);
			for (method in adapter.methods)
				typedFunctions.push(method);
		}
		var enumMethodNames = [for (name in enumMethods.keys()) name];
		enumMethodNames.sort(Reflect.compare);
		for (name in enumMethodNames)
			typedFunctions.push(enumMethods.get(name));
		var hashNames = [for (name in hashes.keys()) name];
		hashNames.sort(Reflect.compare);
		for (name in hashNames)
			typedFunctions.push(hashes.get(name));
		var equalityNames = [for (name in equalities.keys()) name];
		equalityNames.sort(Reflect.compare);
		for (name in equalityNames)
			typedFunctions.push(equalities.get(name));
		var copyNames = [for (name in dynamicStructures.keys()) name];
		copyNames.sort(Reflect.compare);
		for (name in copyNames)
			typedFunctions.push(dynamicStructures.get(name));
		keepAnonymousUnits(cachedMetadata != null ? cachedMetadata : retained != null ? retained.program : null,
			program.classes, retained == null ? null : retained.units);
		assembler.registerProgramTypes(typedFunctions, typedClasses, typedInterfaces, typedEnums, typedNatives);
		var nativeTypeDescriptors = bodyTyper.expressionTyper.nativeTypeDescriptors();
		var generatedDoneAt = Sys.time() * 1000.0;
		var allocationAfterGenerated = AllocationMeter.sample();
		semantic.lifecycle.advanceAll(BodyTyped);
		var bodyTransitionDoneAt = Sys.time() * 1000.0;
		var result:TypedProgram = assembler.assemble(typedEnums, typedInterfaces, typedClasses, typedFunctions,
			typedNatives, nativeTypeDescriptors);
		var assemblyDoneAt = Sys.time() * 1000.0;
		var allocationAfterAssembly = AllocationMeter.sample();
		semantic.lifecycle.advanceAll(Finalized);
		var finalizationDoneAt = Sys.time() * 1000.0;
		var typedRuntimeDependencies = assembler.runtimeDependencies();
		var allocationAfterFinalize = AllocationMeter.sample();
		var inferredSignatures = requiredTypes().typedSignatures();
		requiredTypes().endTyping();
		return {
			program: result,
			runtimeDependencies: typedRuntimeDependencies,
			typedUnits: session.programOutput.records.typedUnits,
			inferredSignatures: inferredSignatures,
			keyPathUses: session.programOutput.records.keyPathUsesByUnit(),
			metrics: {
				allocationPhases: [
					AllocationMeter.delta("typer-setup", allocationAtStart, allocationAfterSetup),
					AllocationMeter.delta("typer-no-return", allocationAfterSetup, allocationAfterNoReturn),
					AllocationMeter.delta("typer-metadata", allocationAfterNoReturn, allocationAfterMetadata),
					AllocationMeter.delta("typer-class-bodies", allocationAfterMetadata, allocationAfterClassBodies),
					AllocationMeter.delta("typer-function-bodies", allocationAfterClassBodies,
						allocationAfterFunctionBodies),
					AllocationMeter.delta("typer-generated", allocationAfterFunctionBodies, allocationAfterGenerated),
					AllocationMeter.delta("typer-assembly", allocationAfterGenerated, allocationAfterAssembly),
					AllocationMeter.delta("typer-finalize", allocationAfterAssembly, allocationAfterFinalize)
				],
				declarationMs: semantic.lifecycleMetrics.declarationMs,
				shapeConnectionMs: semantic.lifecycleMetrics.shapeConnectionMs,
				signatureTypingMs: semantic.lifecycleMetrics.signatureTypingMs,
				setupMs: setupDoneAt - startedAt,
				noReturnMs: noReturnDoneAt - setupDoneAt,
				metadataMs: metadataDoneAt - noReturnDoneAt,
				classBodiesMs: classBodiesDoneAt - metadataDoneAt,
				functionBodiesMs: functionBodiesDoneAt - classBodiesDoneAt,
				generatedMs: generatedDoneAt - functionBodiesDoneAt,
				bodyTransitionMs: bodyTransitionDoneAt - generatedDoneAt,
				assemblyMs: assemblyDoneAt - bodyTransitionDoneAt,
				finalizationMs: finalizationDoneAt - assemblyDoneAt
			}
		};
	}

	/**
		Ask again for the enum and class specializations of the previous program and return its other retained generated
		classes. A class no source declares (a key path cache) keeps only the static fields retained code reads, so a cache
		does not collect fields for paths nothing uses any more.
	**/
	/**
	 * A unit this build did not type keeps the anonymous types it registered when it was typed, as long as it still exists: the
	 * program lists them, and so does a fresh build, which types every unit. A field's initializer is the unit `Class.__init.x`
	 * (`InitializerUnit`); a generated function (a specialization, a lambda) exists while the build keeps it (`kept`).
	 */
	function keepAnonymousUnits(previous:Null<TypedProgram>, classes:Array<AstClass>,
			kept:Null<Map<String, Bool>>):Void {
		if (previous == null)
			return;
		var fields:Map<String, Bool> = [], registry = new AnonymousTypeRegistry(session);
		for (classDecl in classes)
			for (field in classDecl.fields)
				if (field.initializer != null)
					fields.set(classDecl.name + "." + field.name, true);
		for (unit => types in previous.anonymousUnits) {
			if (session.programOutput.records.typedUnits.exists(unit)
				|| session.programOutput.records.hasAnonymousUnit(unit))
				continue;
			var initialized = InitializerUnit.field(unit),
				exists = session.signatures.exists(unit) || initialized != null && fields.exists(initialized)
					|| kept != null && kept.exists(unit);
			if (!exists)
				continue;
			// Outside any body, registering a type only discovers it for the program (`AnonymousTypeRegistry.register`).
			for (entry in types)
				registry.discover(TAnonymous(entry.name, entry.fields));
			session.programOutput.records.keepAnonymousUnit(unit, types);
		}
	}

	function takeFromPrevious(retained:RetainedFromPrevious):Array<TypedClass> {
		var previous = retained.program, carried:Array<TypedClass> = [];
		session.enumRepresentations.restore(previous.enums, retained.enums);
		session.representation.restoreGenericOwnerAliases(previous.genericOwnerAliases, retained.classes);
		for (cached in previous.classes) {
			if (!retained.classes.exists(cached.name))
				continue;
			if (cached.specializationOrigin != null) {
				if (cached.specializationArguments != null
					&& session.classDecls.exists(cached.specializationOrigin)
					&& session.representation.typeNamesExist(cached.specializationArguments))
					session.representation.genericOwner(TInstance(NominalKind.Class, cached.specializationOrigin,
						cached.specializationArguments));
			} else if (!session.classDecls.exists(cached.name)) {
				carried.push({
					name: cached.name,
					genericParameters: cached.genericParameters,
					isValue: cached.isValue,
					isFlat: cached.isFlat,
					isPortable: cached.isPortable,
					isNativeValue: cached.isNativeValue,
					nativeLayouts: cached.nativeLayouts,
					base: cached.base,
					interfaces: cached.interfaces,
					fields: cached.fields.copy(),
					methods: cached.methods,
					span: cached.span
				});
			}
		}
		return carried;
	}

	/**
	 * The cached classes this build types again: those a selected function is named under, or whose file changed. The others'
	 * unannotated fields keep the types they were typed with (`seedFieldTypes`), given before anything reads them.
	 */
	function classesToRefresh(parsed:Array<AstClass>, cached:Array<TypedClass>,
			selected:Null<Map<String, Bool>>):Map<String, Bool> {
		var parsedByName = [for (decl in parsed) decl.name => decl], refreshing:Map<String, Bool> = [];
		// A class is refreshed when a selected function is named under it. Checking that against every selected name for
		// every class is quadratic (millions of string concatenations in a large program), so collect the dotted prefixes
		// of the selected names once: a class is changed when its name is one of them.
		var owners:Map<String, Bool> = [];
		if (selected != null)
			for (name in selected.keys()) {
				var dot = name.indexOf(".");
				while (dot >= 0) {
					owners.set(name.substr(0, dot), true);
					dot = name.indexOf(".", dot + 1);
				}
			}
		for (cachedClass in cached) {
			var declaration = parsedByName.get(cachedClass.name);
			if (declaration == null)
				continue;
			// The typed class holds a generic class's field types erased, not in its type parameters, so it is typed again.
			if (declaration.typeParameters.length > 0 && hasInferredField(declaration)
				|| selected != null
				&& (owners.exists(cachedClass.name) || declaration.span.file != cachedClass.span.file))
				refreshing.set(cachedClass.name, true);
			else
				seedFieldTypes(declaration, cachedClass);
		}
		return refreshing;
	}

	function refreshCachedClasses(parsed:Array<AstClass>, cached:Array<TypedClass>, selected:Null<Map<String, Bool>>,
			refreshing:Map<String, Bool>):Array<TypedClass> {
		var parsedByName = [for (decl in parsed) decl.name => decl];
		return [for (cachedClass in cached) {
			if (!refreshing.exists(cachedClass.name)) cachedClass else {
				var refreshed = typeClass(parsedByName.get(cachedClass.name), selected),
					cachedMethods = [for (method in cachedClass.methods) method.name => method];
				var methods = [
					for (method in refreshed.methods)
						selected == null
						|| selected.exists(method.name) ? method : cachedMethods.exists(method.name)
						? cachedMethods.get(method.name) : method
				];
				{
					name:refreshed.name,
						genericParameters:refreshed.genericParameters,
						isValue:refreshed.isValue,
						isFlat:refreshed.isFlat,
						isPortable:refreshed.isPortable,
						isNativeValue:refreshed.isNativeValue,
						nativeLayouts:cachedClass.nativeLayouts,
						base:refreshed.base,
						interfaces:refreshed.interfaces,
						fields:refreshed.fields,
						methods:methods,
						span:refreshed.span
				};
			}
		}];
	}

	static function hasInferredField(declaration:AstClass):Bool {
		for (field in declaration.fields)
			if (field.type == null && !field.isInline)
				return true;
		return false;
	}

	/**
	 * Gives the unannotated fields of `declaration`, which this build does not type again, the types the previous build typed them
	 * with: the declaration is unchanged and, by the invalidation rule, so is every type its initializers read
	 * (docs/design/LAZY_DECLARATION_TYPING.md, "Warm builds: reused declarations").
	 */
	function seedFieldTypes(declaration:AstClass, cachedClass:TypedClass):Void {
		var cachedFields = [for (field in cachedClass.fields) field.name => field];
		for (field in declaration.fields)
			if (field.type == null) {
				var cachedField = cachedFields.get(field.name);
				if (cachedField != null)
					requiredTypes().seedField(DeclarationTypeTable.fieldKey(declaration.name, field), cachedField.type);
			}
	}

	function bindCachedNativeLayouts(classes:Array<TypedClass>):Void
		for (classDecl in classes)
			if (classDecl.isNativeValue || classDecl.isFlat)
				for (layout in classDecl.nativeLayouts)
					if (layout.target == session.nativeAbiTarget)
						session.nativeLayoutsByName.set(classDecl.name, layout);

	/**
	 * Types `classDecl`: its fields, their initializers and its method signatures, and its method bodies unless they are deferred. A
	 * declared class's field initializers are units of their own, whose outputs are added to `fieldUnits` in declaration order, or
	 * merged into the program's at once without it.
	 */
	function typeClass(classDecl:AstClass, selected:Null<Map<String, Bool>>, deferMethodBodies:Bool = false,
			?specialization:compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation,
			?fieldUnits:Array<TypingOutput>):TypedClass {
		if (specialization == null && fieldUnits == null) {
			var units:Array<TypingOutput> = [], typed = typeClass(classDecl, selected, deferMethodBodies, null, units);
			session.mergeUnits(units);
			return typed;
		}
		var isStruct = classDecl.isStruct == true,
			requestedValue = isStruct || hasMetadata(classDecl.metadata, "value"),
			isNativeValue = validateRepresentationMetadata(classDecl.metadata, requestedValue),
			isValue = requestedValue && !isNativeValue;
		validateStructPropertyMetadata(classDecl, isValue, isNativeValue);
		// Reject value capabilities on reference declarations before typing their fields or initializers.
		if (!isStruct && (classDecl.interfaces.length > 0 || classDecl.base != null)) {
			var actual = TInstance(NominalKind.Class, classDecl.name, [
				for (parameter in classDecl.typeParameters)
					TTypeParameter(classDecl.name, parameter)
			]);
			for (capability in ["Hashable", "Equatable"])
				if (session.relations.isAssignable(actual, TInstance(NominalKind.Interface, capability, [])))
					BodyTyper.fail(DiagnosticCode.CONFORMANCE,
						'Class "${classDecl.name}" cannot conform to $capability; use a struct for value equality',
						classDecl.span);
		}

		if (isStruct && isNativeValue)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Struct "${classDecl.name}" does not use @:repr; native layout is inferred from its fields',
				classDecl.span);
		if (isStruct && classDecl.typeParameters.length > 0)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Generic struct "${classDecl.name}" is not supported yet',
				classDecl.span);
		if (isValue)
			validateFiniteValueLayout(classDecl, [], []);
		if ((isValue || isNativeValue) && classDecl.base != null)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Value class "${classDecl.name}" cannot extend another class', classDecl.span);
		if ((isValue && !isStruct || isNativeValue) && classDecl.interfaces.length > 0)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Value class "${classDecl.name}" cannot implement interfaces', classDecl.span);
		if (isNativeValue && classDecl.typeParameters.length > 0)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Native value record "${classDecl.name}" cannot be generic',
				classDecl.span);
		if (isNativeValue) {
			for (field in classDecl.fields) {
				if (field.isStatic)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'Native value record "${classDecl.name}" cannot declare static fields',
						field.span);
				if (field.initializer != null)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'Native value field "${classDecl.name}.${field.name}" cannot have an initializer', field.span);
			}
			for (method in classDecl.methods)
				if (!method.isStatic)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'Native value record "${classDecl.name}" cannot declare instance methods or constructors',
						method.span);
		}
		var fields:Array<TypedField> = [],
			fieldNames:Map<String, Bool> = [],
			erasedSubstitutions = specialization == null
				? session.representation.erasedNominalSubstitutions(classDecl.name) : specialization.substitutions;
		for (field in classDecl.fields) {
			if (specialization != null && field.isStatic)
				continue;
			if (fieldNames.exists(field.name))
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT, 'Duplicate field "${classDecl.name}.${field.name}"',
					field.span);
			if (field.isInline && !field.isStatic)
				BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
					'Inline field "${classDecl.name}.${field.name}" must be static', field.span);
			if (field.isInline && field.initializer == null)
				BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
					'Inline field "${classDecl.name}.${field.name}" requires an initializer',
					field.span);
			var type = session.declarations.types.fieldType(classDecl.name, field, erasedSubstitutions);
			if ((switch (type) {
				case TVoid: true;
				default: false;
			}))
				BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
				'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			if (!requestedValue && !isNativeValue && NativeLayout.containsUnsupportedRuntimeValueType(type))
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Native layout types can only appear in value structs or native value record fields', field.span);
			var initializer:Null<TypedExpression> = null,
				initializerContextWarnings:Null<Array<compiler.core.Diagnostic>> = null,
				inlineValue:Null<TypedExpression> = null,
				parsedInitializer = field.initializer;
			if (parsedInitializer != null) {
				if (field.isInline) {
					var resolved = bodyTyper.resolveInlineConstant(classDecl.name, field.name, field.span);
					if (resolved == null)
						BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
							'Unable to resolve inline constant "${classDecl.name}.${field.name}"',
							field.span);
					initializer = resolved.initializer;
					inlineValue = resolved.value;
				} else if (specialization == null) {
					// A declared class's initializer is a unit of its own, typed here or earlier, when its type was first needed. One
					// that fails is recorded and the field is kept without it, so the next body is typed.
					var unit = requiredTypes().fieldInitializer(classDecl, field, type);
					initializer = unit.initializer;
					initializerContextWarnings = unit.warnings;
					if (unit.output != null && fieldUnits != null)
						fieldUnits.push(unit.output);
				} else {
					// A specialization's initializers are typed as its owner is requested, and fail the body that asked for it.
					var initializerContext = bodyTyper.enterBody(InitializerUnit.of(specialization.name, field.name),
						erasedSubstitutions, classDecl.name),
						scope = new Scope();
					initializerContext.memberInitializer = !field.isStatic;
					if (!field.isStatic)
						scope.defineReceiver(session.representation.receiverType(classDecl.name, erasedSubstitutions),
							field.span);
					initializer = bodyTyper.typeFieldInitializer(field, scope, type,
						initializerLabel(classDecl, field));
					bodyTyper.leaveBody(initializerContext);
					initializerContextWarnings = initializerContext.warnings;
				}
			}
			fieldNames.set(field.name, true);
			fields.push({
				name: field.name,
				metadata: field.metadata,
				type: type,
				initializer: initializer,
				inlineValue: inlineValue,
				readAccess: field.readAccess,
				writeAccess: field.writeAccess,
				isStatic: field.isStatic,
				isInline: field.isInline,
				isFinal: field.isFinal,
				span: field.span,
				warnings: initializerContextWarnings
			});
		}
		for (method in classDecl.methods) {
			if (method.name == "new" || method.isDynamic != true || !method.isStatic
				&& DynamicMethods.inherited(session, classDecl, method.name))
				continue;
			fields.push(DynamicMethods.field(session, classDecl.name, method, erasedSubstitutions));
		}
		var abstractOwner = compiler.semantic.TypeStatics.ownerOf(classDecl.name),
			abstractDecl = abstractOwner == null ? null : session.declarations.abstracts.get(abstractOwner);
		if (abstractDecl != null)
			for (method in abstractDecl.methods)
				if (method.isDynamic == true)
					fields.push(DynamicMethods.field(session, classDecl.name, method, [], abstractOwner));
		var propertyFacts = StructProperties.evaluate(session.declarations,
			TInstance(NominalKind.Class, classDecl.name, []));
		for (metadata in classDecl.metadata) {
			if (metadata.name == "flat" && !propertyFacts.flat)
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Struct "${classDecl.name}" asserts @:flat but field "${propertyFacts.flatPath}" is not Flat',
					metadata.span);
			if (metadata.name == "portable" && !propertyFacts.portable)
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Struct "${classDecl.name}" asserts @:portable but field "${propertyFacts.portablePath}" is not Portable',
					metadata.span);
		}
		var classSemanticSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			classSemanticSubstitutions.set(parameter, TTypeParameter(classDecl.name, parameter));
		for (interfaceType in classDecl.interfaces) {
			var interfaceInstance = session.declarations.resolve(interfaceType, classDecl.span,
				classSemanticSubstitutions),
				interfaceName = BodyTyper.inheritanceName(interfaceType);
			if (!session.interfaceDecls.exists(interfaceName) && !StructProperties.isConstraintType(interfaceInstance))
				throw new CompileError(Diagnostic.unresolved(DiagnosticCode.DECLARATION_OR_MODIFIER,
					UnresolvedNameKind.WantedInterface, interfaceName,
					classDecl.span));
			validateInterfaceImplementation(classDecl, interfaceInstance, classSemanticSubstitutions, classDecl.span);
		}
		var declaredType = TInstance(NominalKind.Class, classDecl.name, [
			for (parameter in classDecl.typeParameters)
				TTypeParameter(classDecl.name, parameter)
		]);
		validateObservable(classDecl, declaredType, classSemanticSubstitutions, isValue, isNativeValue);
		validateDeclaredConformance(classDecl, declaredType, classSemanticSubstitutions);
		if (specialization == null)
			session.declarations.validateInferredOverrides(classDecl);
		var parsedBase = classDecl.base, baseName:Null<String> = null;
		if (parsedBase != null) {
			baseName = BodyTyper.inheritanceName(parsedBase);
			var baseType = session.declarations.resolve(parsedBase, classDecl.span, erasedSubstitutions),
				baseSpecialization = session.representation.genericOwner(baseType);
			if (baseSpecialization != null)
				baseName = baseSpecialization.name;
		}
		return {
			name: specialization == null ? classDecl.name : specialization.name,
			genericParameters: specialization == null ? classDecl.typeParameters : [],
			specializationOrigin: specialization == null ? null : specialization.origin,
			specializationArguments: specialization == null ? null : specialization.typeArguments,
			isValue: isValue,
			isFlat: propertyFacts.flat,
			isPortable: propertyFacts.portable,
			isNativeValue: isNativeValue,
			nativeLayouts: [],
			base: baseName,
			interfaces: [
				for (interfaceType in classDecl.interfaces)
					if (!StructProperties.isConstraintSyntax(interfaceType)) BodyTyper.inheritanceName(interfaceType)
			],
			fields: fields,
			methods: typeClassMethods(classDecl, fields, selected, deferMethodBodies, erasedSubstitutions,
				specialization),
			span: classDecl.span
		};
	}

	function validateObservable(classDecl:AstClass, declaredType:CompilerType,
			classSemanticSubstitutions:Map<String, CompilerType>, isValue:Bool,
			isNativeValue:Bool):Void {
		if (!DeclaredConformance.has(session, declaredType, "Observable"))
			return;
		// Observable field access is generated after typing. Its per-object source is
		// therefore an implicit module dependency even when user code imports none of
		// the reactive runtime classes.
		session.runtimeDependencyTracker.record(classDecl.name + ".new", RuntimeType.OBSERVABLE_SOURCE);
		session.runtimeDependencyTracker.record(classDecl.name + ".new", RuntimeType.REACTIVE_RUNTIME);
		if (isValue || isNativeValue)
			BodyTyper.fail(DiagnosticCode.CONFORMANCE,
				'Observable conformance is only supported on classes with identity: "${classDecl.name}"',
				classDecl.span);
		if (classDecl.base != null) {
			var baseType = session.declarations.resolve(classDecl.base, classDecl.span, classSemanticSubstitutions);
			if (!DeclaredConformance.has(session, baseType, "Observable"))
				BodyTyper.fail(DiagnosticCode.CONFORMANCE,
					'Observable class "${classDecl.name}" must extend an Observable base class',
					classDecl.span);
		}
		for (field in DiffIntrinsics.storedFields(classDecl)) {
			var fieldType = session.declarations.types.fieldType(classDecl.name, field, classSemanticSubstitutions);
			var enumField = switch fieldType {
				case TInstance(NominalKind.Enum, _, _), TNullable(TInstance(NominalKind.Enum, _, _)): true;
				default: false;
			};
			if (enumField && DeclaredConformance.supportsEquality(session, fieldType))
				EnumEqualityGenerator.request(session, fieldType, classDecl.name + ".new", field.span);
			else if (DeclaredConformance.usesEquality(session, fieldType))
				ValueEqualityGenerator.request(session, fieldType, classDecl.name + ".new", field.span);
		}
	}

	function validateDeclaredConformance(classDecl:AstClass, declaredType:CompilerType,
			classSemanticSubstitutions:Map<String, CompilerType>):Void {
		if (!session.relations.isStruct(declaredType))
			return;
		if (DeclaredConformance.has(session, declaredType, "Equatable")) {
			var hasEquals = false, hasHash = false;
			for (method in classDecl.methods)
				if (method.name == "equals") {
					hasEquals = true;
					if (method.isStatic
						|| method.arguments.length != 1
						|| !TypeRelations.equals(session.declarations.resolve(method.arguments[0].type, method.span,
						classSemanticSubstitutions), declaredType)
						|| !TypeRelations.equals(session.declarations.types.resultType(method,
						classSemanticSubstitutions), TBool))
						BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
							'Method "${classDecl.name}.equals" must have signature equals(other:${classDecl.name}):Bool',
							method.span);
				} else if (method.name == "hash" && DeclaredConformance.has(session, declaredType, "Hashable")) {
					hasHash = true;
					if (method.isStatic
						|| method.arguments.length != 0
						|| !TypeRelations.equals(session.declarations.types.resultType(method,
						classSemanticSubstitutions), TInt))
						BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
							'Method "${classDecl.name}.hash" must have signature hash():Int',
							method.span);
				}
			if (!hasEquals)
				for (entry in DiffIntrinsics.conformanceFields(session, declaredType)) {
					var field = entry.field, fieldType = entry.type;
					if (!DeclaredConformance.supportsEquality(session, fieldType))
						BodyTyper.fail(DiagnosticCode.CONFORMANCE,
							'Cannot synthesize Equatable for "${classDecl.name}": field "${field.name}" does not conform to Equatable',
							field.span);
				}
			if (DeclaredConformance.has(session, declaredType, "Hashable") && !hasHash) {
				if (hasEquals)
					BodyTyper.fail(DiagnosticCode.CONFORMANCE,
						'Cannot synthesize Hashable for "${classDecl.name}" with a handwritten equals; provide hash():Int',
						classDecl.span);
				var hashFields = DiffIntrinsics.conformanceFields(session, declaredType);
				for (entry in hashFields) {
					var field = entry.field, fieldType = entry.type;
					if (!DeclaredConformance.supportsHash(session, fieldType))
						BodyTyper.fail(DiagnosticCode.CONFORMANCE,
							'Cannot synthesize Hashable for "${classDecl.name}": field "${field.name}" does not conform to Hashable',
							field.span);
				}
			}
		}
	}

	function validateEnumInterface(declaration:compiler.syntax.Ast.AstEnum, interfaceType:CompilerType,
			enumSubstitutions:Map<String, CompilerType>):Void {
		var interfaceName = switch interfaceType {
			case TInstance(NominalKind.Interface, name, _): name;
			default:
				BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
					'Enum "${declaration.name}" must implement an interface', declaration.span);
				return;
		};
		var contract = session.interfaceDecls.get(interfaceName);
		if (contract == null)
			throw new CompileError(Diagnostic.unresolved(DiagnosticCode.DECLARATION_OR_MODIFIER,
				UnresolvedNameKind.WantedInterface, interfaceName,
				declaration.span));
		var interfaceSubstitutions = session.representation.nominalSubstitutions(interfaceType);
		for (base in contract.bases)
			validateEnumInterface(declaration, session.declarations.resolve(base, contract.span,
				interfaceSubstitutions), enumSubstitutions);
		for (method in contract.methods) {
			var implementation:Null<AstFunction> = null;
			if (declaration.methods != null)
				for (candidate in declaration.methods)
					if (candidate.name == method.name)
						implementation = candidate;
			if (implementation == null || implementation.isStatic)
				BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
					'Enum "${declaration.name}" does not implement "$interfaceName.${method.name}"',
					declaration.span);
			if ((implementation.typeParameters != null && implementation.typeParameters.length > 0)
				|| !sameSignature(implementation, method, enumSubstitutions, interfaceSubstitutions))
				BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
					'Method "${declaration.name}.${method.name}" does not match interface "$interfaceName"',
					implementation.span);
		}
	}

	/** Equality and hashing are properties of the enum type, not its chosen physical representation. */
	function validateEnumConformance(declaration:compiler.syntax.Ast.AstEnum):Void {
		var substitutions:Map<String, CompilerType> = [];
		for (parameter in declaration.typeParameters)
			substitutions.set(parameter, TTypeParameter(declaration.name, parameter));
		if (declaration.conformances != null)
			for (conformance in declaration.conformances) {
				var resolved = session.declarations.resolve(conformance, declaration.span, substitutions);
				validateEnumInterface(declaration, resolved, substitutions);
			}
		var type:CompilerType = TInstance(NominalKind.Enum, declaration.name,
			[for (parameter in declaration.typeParameters) substitutions.get(parameter)]),
			equatable = DeclaredConformance.has(session, type, "Equatable"),
			hashable = DeclaredConformance.has(session, type, "Hashable"),
			hasEquals = false,
			hasHash = false;
		var hasPayload = false;
		for (constructor in declaration.cases)
			if (constructor.params.length > 0)
				hasPayload = true;
		validateEnumConstants(declaration, substitutions);
		var seenMethods:Map<String, Bool> = [];
		if (declaration.methods != null)
			for (method in declaration.methods) {
				if (seenMethods.exists(method.name))
					BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
						'Duplicate method "${declaration.name}.${method.name}"', method.span);
				seenMethods.set(method.name, true);
				if (!hasPayload && (method.name == "equals" || method.name == "hash"))
					BodyTyper.fail(DiagnosticCode.CONFORMANCE,
						'Nullary enum "${declaration.name}" uses tag equality and cannot override equals or hash',
						method.span);
				for (constructor in declaration.cases)
					if (constructor.name == method.name)
						BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
							'Enum "${declaration.name}" declares both a case and a method named "${method.name}"',
							method.span);
				if (method.name != "equals" && method.name != "hash")
					continue;
				if (method.name == "equals") {
					hasEquals = true;
					if (!equatable)
						BodyTyper.fail(DiagnosticCode.CONFORMANCE,
							'Enum "${declaration.name}" must declare Equatable to define equals',
							method.span);
					if (method.isStatic
						|| method.arguments.length != 1
						|| (method.typeParameters != null && method.typeParameters.length > 0)
						|| !TypeRelations.equals(session.declarations.resolve(method.arguments[0].type, method.span,
						substitutions), type)
						|| !TypeRelations.equals(session.declarations.types.resultType(method, substitutions),
						TBool))
						BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
							'Method "${declaration.name}.equals" must have signature equals(other:${declaration.name}):Bool',
							method.span);
				} else {
					hasHash = true;
					if (!hashable)
						BodyTyper.fail(DiagnosticCode.CONFORMANCE,
							session.relations.recursiveAnonymousField(type, [],
							null) == null ? 'Enum "${declaration.name}" must declare Hashable to define hash'
							: DeclaredConformance.capabilityError(session,
							type, "Hashable"),
							method.span);
					if (method.isStatic
						|| method.arguments.length != 0
						|| (method.typeParameters != null && method.typeParameters.length > 0)
						|| !TypeRelations.equals(session.declarations.types.resultType(method, substitutions),
						TInt))
						BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
							'Method "${declaration.name}.hash" must have signature hash():Int',
							method.span);
				}
			}
		if (hashable && hasEquals && !hasHash)
			BodyTyper.fail(DiagnosticCode.CONFORMANCE,
				'Cannot synthesize Hashable for "${declaration.name}" with a handwritten equals; provide hash():Int',
				declaration.span);
		if (!equatable)
			return;
		for (constructor in declaration.cases)
			for (parameter in constructor.params) {
				var fieldType = session.representation.enumParameterType(declaration.typeParameters, parameter, type),
					field = parameter.name == null ? "payload" : parameter.name;
				if (!hasEquals && !DeclaredConformance.supportsEquality(session, fieldType))
					BodyTyper.fail(DiagnosticCode.CONFORMANCE,
						'Cannot synthesize Equatable for "${declaration.name}": ${constructor.name}.$field does not conform to Equatable',
						parameter.span);
				if (hashable && !hasHash && !DeclaredConformance.supportsHash(session, fieldType))
					BodyTyper.fail(DiagnosticCode.CONFORMANCE,
						'Cannot synthesize Hashable for "${declaration.name}": ${constructor.name}.$field does not conform to Hashable',
						parameter.span);
			}
	}

	/**
	 * An enum's per-case constants (docs/design/ENUM_MEMBERS.md): each has a name of its own and a constant type, and each case
	 * gives each a compile-time constant once, unless the constant has a default.
	 */
	function validateEnumConstants(declaration:compiler.syntax.Ast.AstEnum,
			substitutions:Map<String, CompilerType>):Void {
		var constants = declaration.constants ?? [], owner = declaration.name, declared:Map<String, CompilerType> = [];
		var statics = session.classDecls.get(compiler.semantic.TypeStatics.storageName(owner));
		for (constant in constants) {
			if (declared.exists(constant.name))
				BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
					'Duplicate per-case constant "$owner.${constant.name}"',
					constant.span);
			for (constructor in declaration.cases)
				if (constructor.name == constant.name)
					BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
						'Enum "$owner" declares both a case and a per-case constant named "${constant.name}"',
						constant.span);
			for (method in declaration.methods ?? [])
				if (method.name == constant.name)
					BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
						'Enum "$owner" declares both a method and a per-case constant named "${constant.name}"',
						constant.span);
			if (statics != null)
				for (field in statics.fields)
					if (field.name == constant.name)
						BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
							'Enum "$owner" declares both a static and a per-case constant named "${constant.name}"',
							constant.span);
			var type = session.declarations.resolve(constant.type, constant.span, substitutions);
			if (!constantType(type))
				BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
					'Per-case constant "$owner.${constant.name}" must be Int, Float, Bool, String, an enum without payloads, or Null of one',
					constant.span);
			declared.set(constant.name, type);
			if (constant.defaultValue != null)
				requireConstantValue(owner, constant.name, constant.defaultValue, type);
		}
		for (constructor in declaration.cases) {
			var given:Map<String, Bool> = [];
			for (value in constructor.constants ?? []) {
				var type = declared.get(value.name);
				if (type == null)
					BodyTyper.fail(DiagnosticCode.NAME_OR_MEMBER,
						'Enum "$owner" declares no per-case constant "${value.name}"', value.span);
				if (given.exists(value.name))
					BodyTyper.fail(DiagnosticCode.DECLARATION_CONFLICT,
						'Case "$owner.${constructor.name}" sets "${value.name}" twice', value.span);
				given.set(value.name, true);
				requireConstantValue(owner, value.name, value.value, type);
			}
			for (constant in constants)
				if (constant.defaultValue == null && !given.exists(constant.name))
					BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
						'Case "$owner.${constructor.name}" must set per-case constant "${constant.name}"',
						constructor.span);
		}
	}

	/** Whether a per-case constant may have `type`: a value that is the same for every use of the case. */
	function constantType(type:CompilerType):Bool {
		return switch type {
			case TInt, TFloat, TBool, TString: true;
			case TNullable(element): constantType(element);
			case TInstance(NominalKind.Enum, name, _):
				var enumDecl = session.enumDecls.get(name);
				enumDecl != null && !Lambda.exists(enumDecl.cases, constructor -> constructor.params.length > 0);
			default: false;
		};
	}

	/**
	 * Requires that `value` is a compile-time constant of `type`: a literal, null for a nullable constant, a case of the enum
	 * it holds, or an operator over constants. Its type is checked where the getter types it.
	 */
	function requireConstantValue(owner:String, constant:String, value:compiler.syntax.Ast.AstExpression,
			type:CompilerType):Void {
		var nullable = type.match(TNullable(_)),
			element = switch type {
				case TNullable(inner): inner;
				default: type;
			};
		var span = compiler.syntax.Parser.expressionSpan(value);
		if (!constantExpression(value, element, nullable))
			BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
				'Per-case constant "$owner.$constant" needs a compile-time constant value', span);
		// The value's type, said of the constant rather than of the getter that returns it.
		var given = constantValueType(value);
		if (given != null && !TypeRelations.equals(given, element) && !(given.match(TInt) && element.match(TFloat))
			&& !(given.match(TNull) && nullable))
			BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
				'Per-case constant "$owner.$constant" is ${compiler.semantic.SemanticSignature.display(element)}, not '
				+ compiler.semantic.SemanticSignature.display(given), span);
	}

	/** The type of a constant value, or null for a case of an enum (checked by `constantExpression`). */
	function constantValueType(value:compiler.syntax.Ast.AstExpression):Null<CompilerType> {
		return switch value {
			case IntegerLiteral(_, _): TInt;
			case FloatLiteral(_, _): TFloat;
			case StringLiteral(_, _): TString;
			case BoolLiteral(_, _): TBool;
			case NullLiteral(_): TNull;
			case Not(_, _), And(_, _, _), Or(_, _, _): TBool;
			case Negate(inner, _): constantValueType(inner);
			case Add(left, right, _):
				var l = constantValueType(left), r = constantValueType(right);
				l != null && l.match(TString) || r != null && r.match(TString) ? TString : numeric(l, r);
			case Sub(left, right, _), Mul(left, right, _), Mod(left, right, _):
				numeric(constantValueType(left), constantValueType(right));
			case Div(_, _, _): TFloat;
			case BitAnd(_, _, _), BitOr(_, _, _), BitXor(_, _, _), ShiftLeft(_, _, _), ShiftRight(_, _, _),
				UnsignedShiftRight(_, _, _): TInt;
			default: null;
		};
	}

	static function numeric(left:Null<CompilerType>, right:Null<CompilerType>):Null<CompilerType>
		return left != null && left.match(TFloat) || right != null && right.match(TFloat) ? TFloat : left;

	function constantExpression(value:compiler.syntax.Ast.AstExpression, type:CompilerType, nullable:Bool):Bool {
		return switch value {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _): true;
			case NullLiteral(_): nullable;
			case Negate(inner, _), Not(inner, _): constantExpression(inner, type, false);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _),
				Mod(left, right, _),
				BitAnd(left, right, _), BitOr(left, right, _), BitXor(left, right, _), ShiftLeft(left, right, _),
				ShiftRight(left, right, _), UnsignedShiftRight(left, right, _), And(left, right, _), Or(left, right, _):
				constantExpression(left, type, false) && constantExpression(right, type, false);
			case Variable(name, _):
				switch type {
					case TInstance(NominalKind.Enum, enumName, _):
						var caseName = name.indexOf(".") < 0 ? name : name.substr(name.lastIndexOf(".") + 1),
							enumDecl = session.enumDecls.get(enumName);
						enumDecl != null && Lambda.exists(enumDecl.cases, constructor -> constructor.name == caseName);
					default: false;
				}
			case Member(Variable(prefix, span), name, _):
				constantExpression(Variable(prefix + "." + name, span), type, false);
			default: false;
		};
	}

	/** A nullable value still contains its payload inline, so it cannot break a by-value cycle. */
	function validateFiniteValueLayout(declaration:AstClass, visiting:Array<String>, complete:Map<String, Bool>):Void {
		var cycle = visiting.indexOf(declaration.name);
		if (cycle >= 0)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Value layout contains a by-value cycle: ${visiting.slice(cycle).concat([declaration.name]).join(" -> ")}',
				declaration.span);
		if (complete.exists(declaration.name))
			return;
		var path = visiting.concat([declaration.name]);
		for (field in declaration.fields) {
			if (field.isStatic || !DiffIntrinsics.hasStoredField(field))
				continue;
			var type = session.declarations.types.fieldType(declaration.name, field);
			validateFiniteValueField(type, path, complete);
		}
		complete.set(declaration.name, true);
	}

	function validateFiniteValueField(type:CompilerType, visiting:Array<String>, complete:Map<String, Bool>):Void {
		switch type {
			case TNullable(element):
				validateFiniteValueField(element, visiting, complete);
			case TAbstract(_, _, representation):
				validateFiniteValueField(representation, visiting, complete);
			case TInstance(NominalKind.Class, name, _) if (session.relations.isValueClass(type)):
				var nested = session.declarations.classes.get(name);
				if (nested != null)
					validateFiniteValueLayout(nested, visiting, complete);
			default:
		}
	}

	/** The indices `0...count` in the order units are typed: declaration order, or reversed. */
	function typingOrder(count:Int):Array<Int> {
		var order = [for (index in 0...count) index];
		if (reverseTypingOrder)
			order.reverse();
		return order;
	}

	/**
	 * The declared classes with their fields and initializers typed and their method bodies deferred, in declaration order.
	 * Each field initializer is a unit (`InitializerUnit`), and so is the rest of each class; their outputs are merged into the
	 * program's once all are typed, each class's initializers first.
	 */
	function typeDeclaredClasses(declarations:Array<AstClass>, selected:Null<Map<String, Bool>>):Array<TypedClass> {
		var typed:Array<Null<TypedClass>> = [for (_ in declarations) null],
			units:Array<Array<TypingOutput>> = [for (_ in declarations)[]];
		for (index in typingOrder(declarations.length)) {
			var classDecl = declarations[index];
			if (classDecl.isExtern != true && externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null) {
				var unit = session.beginUnit(), fieldUnits:Array<TypingOutput> = [];
				typed[index] = typeClass(classDecl, selected, true, null, fieldUnits);
				session.endUnit(unit);
				fieldUnits.push(unit);
				units[index] = fieldUnits;
			}
		}
		session.mergeUnits([for (classUnits in units) for (unit in classUnits) unit]);
		return [for (typedClass in typed) if (typedClass != null) typedClass];
	}

	/** The label of `field`'s initializer in an error that its value does not fit the field. */
	static function initializerLabel(classDecl:AstClass, field:compiler.syntax.Ast.AstField):String
		return field.isStatic
			? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"';

	function requiredTypes():DeclarationTypeTable {
		var types = session.types;
		if (types == null)
			throw new InternalError("Field initializers are typed after the program is bound");
		return types;
	}

	public function typeFieldInitializer(classDecl:AstClass, field:compiler.syntax.Ast.AstField,
			type:Null<CompilerType>,
			provisional:CompilerType->Void):{
				initializer:TypedExpression,
				warnings:Array<compiler.core.Diagnostic>,
				type:CompilerType
			} {
		var substitutions = session.representation.erasedNominalSubstitutions(classDecl.name),
			context = bodyTyper.enterBody(InitializerUnit.of(classDecl.name, field.name), substitutions,
				classDecl.name),
			scope = new Scope(),
			expression = field.initializer;
		context.memberInitializer = !field.isStatic;
		if (expression == null)
			throw new InternalError('Field "${classDecl.name}.${field.name}" has no initializer');
		if (!field.isStatic)
			scope.defineReceiver(session.representation.receiverType(classDecl.name, substitutions), field.span);
		var initializer = type == null ? bodyTyper.typeInferredFieldInitializer(field, scope, classDecl.name,
			provisional) : bodyTyper.typeFieldInitializer(field, scope,
			type,
			initializerLabel(classDecl, field));
		var fieldType = type == null ? initializer.type : type;
		// A generic class's initializers are code typed with its type parameters erased to Dynamic, as its methods are. An
		// unannotated field's type is its initializer's typed with the class's own parameters, always.
		if (type == null && classDecl.typeParameters.length > 0)
			fieldType = ownParameterFieldType(classDecl, field, expression, fieldType);
		bodyTyper.leaveBody(context);
		return {initializer: initializer, warnings: context.warnings, type: fieldType};
	}

	/**
	 * The type of unannotated `field` of generic `classDecl` in the class's own type parameters, as Haxe types it: its initializer
	 * typed with them, in a unit whose output is dropped (the erased typing, `erased`, is the code until erasure is a pass after
	 * typing, docs/design/GENERIC_TYPING_ONCE.md). The two must agree once the parameters are erased, and a structure cannot
	 * mention them; otherwise the field needs an annotation.
	 */
	function ownParameterFieldType(classDecl:AstClass, field:compiler.syntax.Ast.AstField,
			expression:compiler.syntax.Ast.AstExpression, erased:CompilerType):CompilerType {
		var substitutions = BodyTyper.declarationTypeSubstitutions(classDecl.name, classDecl.typeParameters),
			mark = session.checkpoint(),
			begun = session.beginDeclarationUnit(),
			lifted:Null<CompilerType> = null;
		try {
			var context = bodyTyper.enterBody(InitializerUnit.of(classDecl.name, field.name), substitutions,
				classDecl.name),
				scope = new Scope();
			context.memberInitializer = !field.isStatic;
			if (!field.isStatic)
				scope.defineReceiver(session.representation.receiverType(classDecl.name, substitutions), field.span);
			lifted = bodyTyper.typeInferredFieldInitializer(field, scope, classDecl.name, _ -> {}).type;
			bodyTyper.leaveBody(context);
			session.endDeclarationUnit(begun);
		} catch (error:CompileError) {
			// The initializer is wrong in the class's own parameters (`Std.int(x)` of a `T`), as Haxe reports it, though erasing
			// them hid it.
			session.rewind(mark);
			throw error;
		}
		var type = lifted;
		if (type == null || structureMentionsParameter(type)
			|| !TypeRelations.equals(DeclarationTypeTable.substitute(type,
			session.representation.erasedNominalSubstitutions(classDecl.name)), erased))
			BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
				'Cannot infer the type of field "${classDecl.name}.${field.name}" in generic class "${classDecl.name}" from its initializer; annotate it',
				field.span);
		return type;
	}

	/** Whether `type` has a structure that mentions a type parameter, which `DeclarationTypeTable.substitute` does not reach. */
	function structureMentionsParameter(type:CompilerType):Bool
		return switch type {
			case TNullable(element), TArray(element), TIterator(element): structureMentionsParameter(element);
			case TMap(key, value),
				TKeyPath(key, value, _): structureMentionsParameter(key) || structureMentionsParameter(value);
			case TFunction(arguments, result, _):
				structureMentionsParameter(result) || Lambda.exists(arguments, structureMentionsParameter);
			case TInstance(_, _, arguments): Lambda.exists(arguments, structureMentionsParameter);
			case TAbstract(_, arguments, representation):
				Lambda.exists(arguments, structureMentionsParameter) || structureMentionsParameter(representation);
			case TAnonymous(_, _): session.representation.containsTypeParameter(type, []);
			default: false;
		};

	public function inlineFieldType(classDecl:AstClass, field:compiler.syntax.Ast.AstField):CompilerType {
		var resolved = bodyTyper.resolveInlineConstant(classDecl.name, field.name, field.span);
		if (resolved == null)
			BodyTyper.fail(DiagnosticCode.ASSIGNMENT_OR_BINDING,
				'Unable to resolve inline constant "${classDecl.name}.${field.name}"', field.span);
		return resolved.value.type;
	}

	/**
	 * Whether `method` of declared class `classDecl` is typed in its own slot of `typeClassMethods`, with its signature as it is: not
	 * when the class or the method is generic (the slot's body is typed erased, or per specialization) or the class is extern.
	 */
	function hasOwnSlot(classDecl:AstClass, method:AstFunction):Bool
		return classDecl.isExtern != true
			&& externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null
			&& classDecl.typeParameters.length == 0
			&& !BodyTyper.isGeneric(method);

	public function typeInferredFunction(fn:AstFunction, key:String,
			inference:DeclarationTypeTable.FunctionInference):DeclarationTypeTable.InferredFunction {
		var declared = session.signatures.get(key);
		if (declared != null)
			fn = declared;
		var selected = selectedBodies == null || selectedBodies.exists(key),
			info = session.methodInfoOf(key);
		if (info == null) {
			if (selected && fn.isExtern != true && !BodyTyper.isGeneric(fn))
				return {
					typed: bodyTyper.typeFunction(fn, null, false, null, null, null, null, null, inference),
					kept: true
				};
			return signatureOnly(key,
				() -> bodyTyper.typeFunction(fn, null, false, ownSubstitutions(key, [], key, fn), null,
				null, null, null, inference));
		}
		var owner = info.owner, classDecl = session.classDecls.get(owner);
		if (classDecl != null) {
			if (selected && hasOwnSlot(classDecl, fn))
				return {
					typed: bodyTyper.typeFunction(fn, owner, fn.isStatic,
						session.representation.erasedNominalSubstitutions(owner), null, null, null, null, inference),
					kept: true
				};
			return signatureOnly(key, () -> bodyTyper.typeFunction(fn, owner, fn.isStatic,
				ownSubstitutions(owner, classDecl.typeParameters, key, fn), null, null, null, null, inference));
		}
		var abstractDecl = session.declarations.abstracts.get(owner);
		if (abstractDecl == null)
			throw new InternalError('Unannotated function "$key" has no declaration the typer can type');
		var isConstructor = fn.name == "new";
		if (selected && abstractDecl.isExtern != true && fn.isStatic && !isConstructor && !BodyTyper.isGeneric(fn))
			return {
				typed: bodyTyper.typeFunction(fn, owner, true, null, null, null, null, null, inference),
				kept: true
			};
		// An abstract's constructor is typed as each construction inlines it: as a function that returns the representation
		// `this` is assigned (`AbstractConstructorNormalizer`).
		if (isConstructor) {
			var normalized = AbstractConstructorNormalizer.normalize(fn, abstractDecl.underlying);
			requiredTypes().alias(normalized, fn);
			fn = normalized;
		}
		return signatureOnly(key, () -> typeAbstractBodyUnspecialized(abstractDecl, fn, key, inference));
	}

	/**
	 * Types the body of `fn`, an instance method of `abstractDecl` or its constructor (normalized), whose code is typed per call,
	 * with its own and the abstract's type parameters as themselves, the way Haxe types every member once.
	 */
	function typeAbstractBodyUnspecialized(abstractDecl:compiler.syntax.Ast.AstAbstract, fn:AstFunction, key:String,
			?inference:DeclarationTypeTable.FunctionInference):TypedFunction {
		// The signature table's abstract method has the abstract's type parameters among its own.
		var owner = abstractDecl.name,
			substitutions = ownSubstitutions(owner, [], key, fn),
			receiver = fn.isStatic || fn.name == "new" ? null : TAbstract(owner, [
				for (parameter in abstractDecl.typeParameters)
					BodyTyper.requiredMapValue(substitutions, parameter)
			], session.representation.semanticType(abstractDecl.underlying, abstractDecl.span, substitutions));
		return bodyTyper.typeFunction(fn, owner, true, substitutions, null, receiver, null, null, inference);
	}

	/**
	 * Types the body of an abstract's instance method or constructor, which is typed per call (specialized), so an error in one
	 * nothing calls is reported as Haxe reports it. A member of a non-generic abstract is typed once, as the one specialization
	 * every call makes (`GenericInstantiation.typeMemberBody`), merged only if something calls it. Any other is typed for its
	 * errors alone, with its type parameters as themselves, and its code is what each call's specialization types.
	 */
	function checkAbstractMember(abstractDecl:compiler.syntax.Ast.AstAbstract, fn:AstFunction, key:String):Void {
		if (requiredTypes().isInferred(fn)) {
			// An unannotated member's body is typed for its signature, which records its error.
			requiredTypes().resultType(fn);
			return;
		}
		// A constructor is checked as each construction types it (`CallResolver.typeAbstractConstruction`).
		var isConstructor = fn.name == "new",
			body = isConstructor ? AbstractConstructorNormalizer.normalize(fn, abstractDecl.underlying) : fn;
		function reword(error:CompileError):CompileError
			return isConstructor ? AbstractConstructorNormalizer.constructorError(error, key) : error;
		// A member of a non-generic abstract has one body, which every call specializes to: it is typed once, as that body.
		if (abstractDecl.typeParameters.length == 0 && !BodyTyper.isGeneric(fn)) {
			var mark = session.checkpoint();
			try {
				bodyTyper.genericInstantiation.typeMemberBody(key, body, abstractDecl.name, !isConstructor);
			} catch (error:CompileError) {
				session.recover(mark, reword(error));
			}
			return;
		}
		checkBody(key, () -> typeAbstractBodyUnspecialized(abstractDecl, body, key), isConstructor ? reword : null);
	}

	/**
	 * Checks the body of a generic function, method or static of an abstract (`key`, of `owner`, whose type parameters are
	 * `ownerParameters`), whose code is typed per call (specialized), so an error in one nothing calls is reported as Haxe
	 * reports it: typed once with its type parameters as themselves, for its errors alone.
	 */
	function checkGeneric(key:String, fn:AstFunction, owner:Null<String>, ownerParameters:Array<String>):Void {
		if (requiredTypes().isInferred(fn)) {
			// An unannotated function's body is typed for its signature, which records its error.
			requiredTypes().resultType(fn);
			return;
		}
		checkBody(key, () -> bodyTyper.typeFunction(fn, owner, owner != null && fn.isStatic,
			ownSubstitutions(owner == null ? key : owner, ownerParameters, key, fn)));
	}

	/**
	 * Types a body for its errors alone (`TypingSession.beginCheckUnit`): its unit is dropped, and an error is recorded, passed
	 * through `reword` when given, and typing goes on.
	 */
	function checkBody(key:String, type:() -> TypedFunction, ?reword:CompileError->CompileError):Void {
		var mark = session.checkpoint(), unit = session.beginCheckUnit();
		try {
			signatureOnly(key, type);
			session.endUnit(unit);
		} catch (error:CompileError) {
			session.recover(mark, reword == null ? error : reword(error));
		}
	}

	/**
	 * Checks the body of each function bound to a native by `@:hlNative` (`AstFunctions.bindingNative`): Haxe types it, though
	 * HashLink calls the native, so its errors are reported here and the native is the function's code.
	 */
	function checkNativeBoundBodies(program:compiler.syntax.Ast.AstProgram, selected:Null<Map<String, Bool>>):Void {
		function bound(fn:AstFunction, key:String):Bool
			return fn.isExtern == true && fn.statements.length > 0 && AstFunctions.hasMetadata(fn, "hlNative")
				&& (selected == null || selected.exists(key));
		for (fn in program.functions)
			if (bound(fn, fn.name))
				checkBody(fn.name, () -> bodyTyper.typeFunction(AstFunctions.withBody(fn)));
		for (classDecl in program.classes)
			for (method in classDecl.methods) {
				var key = classDecl.name + "." + method.name;
				if (method.isStatic && bound(method, key))
					checkBody(key, () -> bodyTyper.typeFunction(AstFunctions.withBody(method), classDecl.name, true));
			}
		for (abstractDecl in program.abstracts)
			for (method in abstractDecl.methods) {
				var key = abstractDecl.name + "." + method.name;
				if (bound(method, key))
					checkBody(key, () -> method.isStatic ? bodyTyper.typeFunction(AstFunctions.withBody(method),
						abstractDecl.name, true) : typeAbstractBodyUnspecialized(abstractDecl,
						AstFunctions.withBody(method), key));
			}
	}

	/**
	 * Types an unannotated function's body for its signature alone, in a unit the table drops: it is not the function's code, so it
	 * does not count as a unit this build typed.
	 */
	function signatureOnly(key:String, type:() -> TypedFunction):DeclarationTypeTable.InferredFunction {
		var typedUnits = session.programOutput.records.typedUnits, wasTyped = typedUnits.exists(key);
		var typed = type();
		if (!wasTyped)
			typedUnits.remove(key);
		return {typed: typed, kept: false};
	}

	/** Each of `ownerParameters` and of `fn`'s own type parameters as itself, the way a declaration's signature is resolved. */
	static function ownSubstitutions(owner:String, ownerParameters:Array<String>, key:String,
			fn:AstFunction):Map<String, CompilerType> {
		var substitutions = BodyTyper.declarationTypeSubstitutions(owner, ownerParameters);
		for (parameter in BodyTyper.functionTypeParameters(fn))
			if (!substitutions.exists(parameter))
				substitutions.set(parameter, TTypeParameter(key, parameter));
		return substitutions;
	}

	function typeModuleFunctions(functions:Array<AstFunction>, selected:Null<Map<String, Bool>>,
			units:Array<TypingOutput>):Array<TypedFunction> {
		var typed:Array<Null<TypedFunction>> = [for (_ in functions) null],
			outputs:Array<Null<TypingOutput>> = [for (_ in functions) null];
		for (index in typingOrder(functions.length)) {
			var fn = functions[index];
			if (fn.isExtern != true && BodyTyper.isGeneric(fn) && (selected == null || selected.exists(fn.name))) {
				checkGeneric(fn.name, fn, null, []);
				continue;
			}
			if (fn.isExtern != true && !BodyTyper.isGeneric(fn) && (selected == null || selected.exists(fn.name))) {
				// An unannotated function is typed in its own unit when its signature is first needed, and kept for here.
				if (requiredTypes().isInferred(fn)) {
					var unit = requiredTypes().functionUnit(fn);
					if (unit != null) {
						typed[index] = unit.typed;
						outputs[index] = unit.output;
					}
					continue;
				}
				// A body that fails is left out, with its output: its error is recorded and the next body is typed.
				var mark = session.checkpoint(), unit = session.beginUnit();
				try {
					typed[index] = bodyTyper.typeFunction(fn);
					session.endUnit(unit);
					outputs[index] = unit;
				} catch (error:CompileError) {
					session.recover(mark, error);
				}
			}
		}
		for (unit in outputs)
			if (unit != null)
				units.push(unit);
		return [for (fn in typed) if (fn != null) fn];
	}

	function typeAbstractFunctions(abstracts:Array<compiler.syntax.Ast.AstAbstract>, selected:Null<Map<String, Bool>>,
			units:Array<TypingOutput>):Array<TypedFunction> {
		var methods:Array<{owner:String, signature:AstFunction}> = [],
			unspecialized:Array<{owner:compiler.syntax.Ast.AstAbstract, signature:AstFunction, name:String}> = [],
			generic:Array<{owner:String, signature:AstFunction, name:String}> = [];
		for (abstractDecl in abstracts)
			for (method in abstractDecl.methods) {
				var name = abstractDecl.name + "." + method.name;
				if (abstractDecl.isExtern == true || method.isExtern == true
					|| (selected != null && !selected.exists(name)))
					continue;
				var signature = session.signatures.required(name);
				if (method.isStatic && (!BodyTyper.isGeneric(signature) || signature.isDynamic == true))
					methods.push({owner: abstractDecl.name, signature: signature});
				else if (method.isStatic)
					generic.push({owner: abstractDecl.name, signature: signature, name: name});
				else
					unspecialized.push({owner: abstractDecl, signature: signature, name: name});
			}
		var typed:Array<Null<TypedFunction>> = [for (_ in methods) null],
			outputs:Array<Null<TypingOutput>> = [for (_ in methods) null];
		for (index in typingOrder(methods.length)) {
			if (!BodyTyper.isGeneric(methods[index].signature)
				&& requiredTypes().isInferred(methods[index].signature)) {
				var unit = requiredTypes().functionUnit(methods[index].signature);
				if (unit != null) {
					typed[index] = unit.typed;
					outputs[index] = unit.output;
				}
				continue;
			}
			var mark = session.checkpoint(), unit = session.beginUnit();
			try {
				var entry = methods[index];
				typed[index] = BodyTyper.isGeneric(entry.signature)
					? elaboratedMethod(entry.owner, [], entry.signature,
					DynamicMethods.eraseParameters(entry.signature, []), null)
					: bodyTyper.typeFunction(entry.signature, entry.owner, true);
				session.endUnit(unit);
				outputs[index] = unit;
			} catch (error:CompileError) {
				session.recover(mark, error);
			}
		}
		for (index in typingOrder(unspecialized.length))
			checkAbstractMember(unspecialized[index].owner, unspecialized[index].signature, unspecialized[index].name);
		for (index in typingOrder(generic.length))
			checkGeneric(generic[index].name, generic[index].signature, generic[index].owner, []);
		for (unit in outputs)
			if (unit != null)
				units.push(unit);
		return [for (fn in typed) if (fn != null) fn];
	}

	function typeClassBodies(declarations:Array<AstClass>, classes:Array<TypedClass>, selected:Null<Map<String, Bool>>,
			units:Array<TypingOutput>):Array<TypedClass> {
		var byName:Map<String, AstClass> = [for (declaration in declarations) declaration.name => declaration],
			methods:Array<Null<Array<TypedFunction>>> = [for (_ in classes) null],
			outputs:Array<Array<TypingOutput>> = [for (_ in classes)[]];
		for (index in typingOrder(classes.length)) {
			var declaration = byName.get(classes[index].name);
			if (declaration != null) {
				methods[index] = typeClassMethods(declaration, classes[index].fields, selected, false,
					session.representation.erasedNominalSubstitutions(declaration.name), null, outputs[index]);
				if (declaration.isExtern != true
					&& externTyper.nativeLibrary(declaration.name, declaration.metadata) == null)
					for (method in declaration.methods) {
						var key = declaration.name + "." + method.name;
						if (BodyTyper.isGeneric(method) && !DynamicMethods.isDynamic(session, method, declaration.name)
							&& method.isExtern != true
							&& (selected == null || selected.exists(key)))
							checkGeneric(key, method, declaration.name, declaration.typeParameters);
					}
			}
		}
		for (classUnits in outputs)
			for (unit in classUnits)
				units.push(unit);
		return [for (index in 0...classes.length) {
			var typed = classes[index], typedMethods = methods[index];
			if (typedMethods == null) typed else {
				{
					name:typed.name,
						genericParameters:typed.genericParameters,
						isValue:typed.isValue,
						isFlat:typed.isFlat,
						isPortable:typed.isPortable,
						isNativeValue:typed.isNativeValue,
						nativeLayouts:typed.nativeLayouts,
						base:typed.base,
						interfaces:typed.interfaces,
						fields:typed.fields,
						methods:typedMethods,
						span:typed.span
				};
			}
		}];
	}

	function typeClassMethods(classDecl:AstClass, fields:Array<TypedField>, selected:Null<Map<String, Bool>>,
			deferBodies:Bool,
			substitutions:Map<String, CompilerType>,
			?specialization:compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation,
			?units:Array<TypingOutput>):Array<TypedFunction> {
		var typedMethods:Array<TypedFunction> = [],
			instanceInitializers:Array<TypedField> = [],
			hasConstructor = false;
		for (field in fields)
			if (!field.isStatic && field.initializer != null)
				instanceInitializers.push(field);
		// With `units`, each method is a unit, typed into an output kept in declaration order.
		var methodsTyped:Array<Null<TypedFunction>> = [for (_ in classDecl.methods) null],
			methodUnits:Array<Null<TypingOutput>> = [for (_ in classDecl.methods) null];
		// A generic owner's methods are typed outside any unit, as its requests are drained, so always in declaration order.
		var methodOrder = units == null
			? [for (index in 0...classDecl.methods.length) index] : typingOrder(classDecl.methods.length);
		for (methodIndex in methodOrder) {
			var method = classDecl.methods[methodIndex];
			if (specialization != null && method.isStatic)
				continue;
			if (specialization == null && !method.isStatic && isConstrainedOwnerTemplate(classDecl.name))
				continue;
			// An `extern` method has no body: it is a native (`typeProgramPhases`).
			var genericDynamic = BodyTyper.isGeneric(method)
				&& DynamicMethods.isDynamic(session, method, classDecl.name);
			if (BodyTyper.isGeneric(method) && !genericDynamic || method.isExtern == true)
				continue;
			if (method.name == "new")
				hasConstructor = true;
			var qualified = classDecl.name + "." + method.name,
				typeBody = !deferBodies && (specialization != null || selected == null || selected.exists(qualified));
			// An unannotated method of a declared class is typed in its own unit when its signature is first needed, and kept for
			// here. Its unit is merged in declaration order with the others, or at once without them.
			if (typeBody && specialization == null && hasOwnSlot(classDecl, method)
				&& requiredTypes().isInferred(method)) {
				var functionUnit = requiredTypes().functionUnit(method),
					typedMethod = functionUnit == null ? null : functionUnit.typed;
				if (functionUnit != null && typedMethod != null) {
					if (method.name == "new" && instanceInitializers.length > 0)
						typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers);
					methodsTyped[methodIndex] = typedMethod;
					var output = functionUnit.output;
					if (output != null) {
						if (units != null)
							methodUnits[methodIndex] = output;
						else
							session.mergeUnits([output]);
					}
				}
				continue;
			}
			// A declared class's method body that fails is left out, with its output: its error is recorded and the next body is
			// typed. A specialization's fails the body that asked for it.
			var mark = session.checkpoint(), unit = units == null ? null : session.beginUnit();
			try {
				var physical = genericDynamic ? DynamicMethods.eraseParameters(method, substitutions) : substitutions,
					typedMethod = if (!typeBody)
						methodSignature(method, classDecl.name, physical);
				else if (genericDynamic || elaborateGenerics && classDecl.typeParameters.length > 0
					&& !VoidArguments.anyVoid(specialization == null ? null : specialization.typeArguments))
					elaboratedMethod(classDecl.name, classDecl.typeParameters, method, physical, specialization);
				else
					bodyTyper.typeFunction(method, classDecl.name, method.isStatic, physical,
						specialization == null ? null : specialization.name + "." + method.name, null,
						specialization == null ? null : specialization.name,
						specialization == null ? null : specialization.typeArguments);
				if (method.name == "new" && typeBody && instanceInitializers.length > 0)
					typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers,
						specialization == null ? null : session.representation.receiverType(classDecl.name,
						substitutions));
				methodsTyped[methodIndex] = typedMethod;
				if (unit != null)
					session.endUnit(unit);
				methodUnits[methodIndex] = unit;
			} catch (error:CompileError) {
				if (specialization != null || !typeBody)
					throw error;
				session.recover(mark, error);
			}
		}
		// The constructor as this compile typed its body; one it did not type again is only its signature (`methodSignature`).
		var constructor:Null<TypedFunction> = null;
		for (methodIndex in 0...methodsTyped.length) {
			var typedMethod = methodsTyped[methodIndex];
			if (typedMethod != null) {
				typedMethods.push(typedMethod);
				if (typedMethod.isConstructor && !deferBodies
					&& (specialization != null || selected == null
					|| selected.exists(classDecl.name + "." + classDecl.methods[methodIndex].name)))
					constructor = typedMethod;
			}
		}
		if (units != null)
			for (unit in methodUnits)
				if (unit != null)
					units.push(unit);
		if (!hasConstructor
			&& (specialization != null || !isConstrainedOwnerTemplate(classDecl.name))
			&& instanceInitializers.length > 0
			&& !deferBodies
			&& (specialization != null || selected == null || selected.exists(classDecl.name + ".new"))) {
			if (specialization == null)
				session.recordComposedUnit(classDecl.name + ".new");
			typedMethods.push({
				name: (specialization == null ? classDecl.name : specialization.name) + ".new",
				role: specialization == null ? UserFunction : GenericFunction,
				origin: specialization == null ? null : classDecl.name + ".new",
				originKind: specialization == null ? null : compiler.types.TypedAst.FunctionOriginKind.Specialization,
				typeArguments: specialization == null ? null : specialization.typeArguments,
				owner: classDecl.name,
				physicalOwner: specialization == null ? null : specialization.name,
				isStatic: false,
				isConstructor: true,
				arguments: [],
				result: TVoid,
				statements: instanceInitializerStatements(instanceInitializers, classDecl.name,
					specialization == null ? null : session.representation.receiverType(classDecl.name, substitutions)),
				cells: [],
				cellCaptures: [],
				span: classDecl.span,
				warnings: []
			});
		}
		if (specialization == null && !deferBodies) {
			if (!hasConstructor && typedMethods.length > 0 && typedMethods[typedMethods.length - 1].isConstructor)
				constructor = typedMethods[typedMethods.length - 1];
			NullSafetyInitialization.check(session, classDecl, fields, constructor, constructor != null);
		}
		return typedMethods;
	}

	// Elaborate owner parameters and any method parameters sharing an erased callback slot.
	function elaboratedMethod(owner:String, ownerParameters:Array<String>, method:AstFunction,
			substitutions:Map<String, CompilerType>,
			specialization:Null<compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation>):TypedFunction {
		var key = owner + "." + method.name,
			owners = BodyTyper.isGeneric(method) ? [owner, key] : [owner];
		return bodyTyper.typeFunction(method, owner, method.isStatic,
			ownSubstitutions(owner, ownerParameters, key, method),
			specialization == null ? null : specialization.name + "." + method.name, null,
			specialization == null ? null : specialization.name,
			specialization == null ? null : specialization.typeArguments, null,
			new GenericElaboration(owners, substitutions, bodyTyper));
	}

	function isConstrainedOwnerTemplate(name:String):Bool {
		var declaration = session.classDecls.get(name);
		return declaration != null
			&& declaration.typeParameters.length > 0
			&& declaration.typeConstraints != null
			&& declaration.typeConstraints.length > 0;
	}

	function layoutNativeClasses(classes:Array<TypedClass>):Array<TypedClass> {
		var byName:Map<String, TypedClass> = [],
			layoutsByTarget:Map<String, Map<String, TypedNativeLayout>> = [],
			targets = [
				"portable-abi32",
				"portable-abi64",
				"wasm32-wasi",
				"x86_64-pc-linux-gnu",
				"aarch64-unknown-linux-gnu"
			];
		if (targets.indexOf(session.nativeAbiTarget) < 0)
			targets.push(session.nativeAbiTarget);
		for (classDecl in classes)
			byName.set(classDecl.name, classDecl);
		for (target in targets) {
			var layouts:Map<String, TypedNativeLayout> = [];
			for (classDecl in classes)
				if (classDecl.isNativeValue || classDecl.isFlat)
					computeNativeLayout(classDecl.name, target, byName, layouts, []);
			layoutsByTarget.set(target, layouts);
		}
		return [for (classDecl in classes) {
			var hasNativeLayout = classDecl.isNativeValue || classDecl.isFlat,
				nativeLayouts:Array<TypedNativeLayout> = hasNativeLayout ? [
					for (target in targets)
						requiredNativeLayout(layoutsByTarget, target, classDecl.name)
				] : [];
			if (hasNativeLayout) session.nativeLayoutsByName.set(classDecl.name,
				requiredNativeLayout(layoutsByTarget, session.nativeAbiTarget, classDecl.name));
			{
				name:classDecl.name,
					genericParameters:classDecl.genericParameters,
					isValue:classDecl.isValue,
					isFlat:classDecl.isFlat,
					isPortable:classDecl.isPortable,
					isNativeValue:classDecl.isNativeValue,
					nativeLayouts:nativeLayouts,
					base:classDecl.base,
					interfaces:classDecl.interfaces,
					fields:classDecl.fields,
					methods:classDecl.methods,
					span:classDecl.span
			}
		}];
	}

	/**
	 * Gives the session the native layouts of the flat and native-value classes before any body is typed, as `layoutNativeClasses`
	 * computes them again once the classes are typed: a body can read them, and an unannotated declaration's initializer or body is
	 * typed when its type is first needed, which can be while the classes are typed. A layout needs only the field types of those
	 * classes, so a value class's fields must be annotated: their types are its layout.
	 */
	function prepareNativeLayouts(declarations:Array<AstClass>):Void {
		var valueClasses:Array<{declaration:AstClass, isNativeValue:Bool}> = [];
		for (classDecl in declarations) {
			if (classDecl.isExtern == true || externTyper.nativeLibrary(classDecl.name, classDecl.metadata) != null)
				continue;
			var requestedValue = classDecl.isStruct == true || hasMetadata(classDecl.metadata, "value"),
				isNativeValue = validateRepresentationMetadata(classDecl.metadata, requestedValue);
			if (!requestedValue && !isNativeValue) {
				if (hasMetadata(classDecl.metadata, "assertLayout"))
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, "@:assertLayout requires a native layout",
						classDecl.span);
				continue;
			}
			for (field in classDecl.fields)
				if (!field.isStatic && field.type == null)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'${isNativeValue ? "Native value" : "Value"} field "${classDecl.name}.${field.name}" needs a type annotation: its type is part of the layout',
						field.span);
			// A generic value class is rejected when the class is typed: it has no layout.
			if (classDecl.typeParameters.length == 0)
				valueClasses.push({declaration: classDecl, isNativeValue: isNativeValue});
		}
		var records:Array<TypedClass> = [];
		for (entry in valueClasses) {
			var classDecl = entry.declaration,
				isFlat = StructProperties.evaluate(session.declarations,
					TInstance(NominalKind.Class, classDecl.name, [])).flat;
			if (!entry.isNativeValue && !isFlat)
				continue;
			records.push({
				name: classDecl.name,
				isValue: !entry.isNativeValue,
				isFlat: isFlat,
				isPortable: false,
				isNativeValue: entry.isNativeValue,
				nativeLayouts: [],
				base: null,
				interfaces: [],
				fields: [for (field in classDecl.fields) if (!field.isStatic) {
					name: field.name,
					metadata: field.metadata,
					type: session.declarations.types.fieldType(classDecl.name, field),
					initializer: null,
					inlineValue: null,
					readAccess: field.readAccess,
					writeAccess: field.writeAccess,
					isStatic: false,
					isInline: field.isInline,
					isFinal: field.isFinal,
					span: field.span
				}],
				methods: [],
				span: classDecl.span
			});
		}
		layoutNativeClasses(records);
		for (entry in valueClasses) {
			var declaration = entry.declaration;
			for (metadata in declaration.metadata)
				if (metadata.name == "assertLayout")
					validateLayoutAssertion(declaration.name, metadata);
		}
	}

	function validateLayoutAssertion(name:String, metadata:compiler.syntax.Ast.AstMetadata):Void {
		var layout = session.nativeLayoutsByName.get(name);
		if (layout == null)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, "@:assertLayout requires a native layout", metadata.span);
		var args = metadata.arguments;
		if (args.length == 0 || args.length % 2 == 0)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				"@:assertLayout expects a size followed by field names and offsets", metadata.span);

		function expected(index:Int):Int {
			return switch args[index] {
				case IntegerLiteral(value, _) if (value >= 0): value;
				case _:
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, "@:assertLayout expects a non-negative integer",
						metadata.span);
					0;
			}
		}

		var size = expected(0);
		if (layout.size != size)
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'sizeof<$name>() is ${layout.size}, expected $size',
				metadata.span);
		for (index in 0...Std.int(args.length / 2)) {
			var argument = 1 + index * 2;
			var field = switch args[argument] {
				case StringLiteral(value, _): value;
				case _:
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, "@:assertLayout expects a field name string",
						metadata.span);
					"";
			}
			var actual = Lambda.find(layout.fields, candidate -> candidate.name == field);
			if (actual == null)
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Record "$name" has no field "$field"', metadata.span);
			var offset = expected(argument + 1);
			if (actual.offset != offset)
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'offsetof<$name>("$field") is ${actual.offset}, expected $offset',
					metadata.span);
		}
	}

	static function requiredNativeLayout(layoutsByTarget:Map<String, Map<String, TypedNativeLayout>>, target:String,
			name:String):TypedNativeLayout {
		var layouts = layoutsByTarget.get(target);
		if (layouts == null)
			throw new InternalError('Missing native layout target "$target"');
		var layout = layouts.get(name);
		if (layout == null)
			throw new InternalError('Missing native layout for "$name" on target "$target"');
		return layout;
	}

	function computeNativeLayout(name:String, target:String, classes:Map<String, TypedClass>,
			layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>):TypedNativeLayout {
		var cached = layouts.get(name);
		if (cached != null)
			return cached;
		var key = target + ":" + name, declaration = classes.get(name);
		if (declaration == null || (!declaration.isNativeValue && !declaration.isFlat))
			throw new InternalError('Missing flat or native value record "$name"');
		if (visiting.exists(key))
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Flat value record "$name" contains a by-value layout cycle',
				declaration.span);
		visiting.set(key, true);
		var nativeDeclarations:Map<String, HxiDeclaration> = [];
		for (field in declaration.fields)
			if (!field.isStatic)
				collectNestedNativeDeclarations(field.type, target, classes, layouts, visiting, nativeDeclarations,
					field.span);
		var layout:TypedNativeLayout = try NativeLayout.record(target, name, [for (field in declaration.fields)
			if (!field.isStatic) {
				name: field.name, type: compiler.types.StructProperties.isTagEnum(session.declarations,
					field.type) ? TInt : field.type, span: field.span
			}], nativeDeclarations, declaration.span) catch (error:haxe.Exception) {
				visiting.remove(key);
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Invalid flat value record "$name": ${Std.string(error)}',
					declaration.span);
				cast null;
			};
		visiting.remove(key);
		layouts.set(name, layout);
		return layout;
	}

	function collectNestedNativeDeclarations(type:CompilerType, target:String, classes:Map<String, TypedClass>,
			layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>, result:Map<String, HxiDeclaration>, span:SourceSpan):Void {
		switch type {
			case TAbstract(_, _, representation):
				collectNestedNativeDeclarations(representation, target, classes, layouts, visiting, result, span);
			case TInstance(NominalKind.NativeValue, name, arguments):
				if (arguments.length != 0)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'Generic native value field "$name" has no fixed layout', span);
				addNestedNativeDeclaration(name, target, classes, layouts, visiting, result);
			case TInstance(NominalKind.Class, name, arguments):
				if (arguments.length != 0)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Generic struct field "$name" has no fixed layout',
						span);
				addNestedNativeDeclaration(name, target, classes, layouts, visiting, result);
			case _:
		}
	}

	function addNestedNativeDeclaration(name:String, target:String, classes:Map<String, TypedClass>,
			layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>, result:Map<String, HxiDeclaration>):Void {
		var nested = computeNativeLayout(name, target, classes, layouts, visiting),
			nestedClass = classes.get(name);
		if (nestedClass == null)
			throw new InternalError('Missing flat or native value record "$name"');
		result.set(name, NativeLayout.nestedDeclaration(name, nested, nestedClass.span));
	}

	function erasureType(declaration:compiler.syntax.Ast.AstInterface, type:compiler.syntax.Ast.AstType,
			span:SourceSpan):CompilerType {
		return session.representation.physicalType(type, span,
			session.representation.erasedNominalSubstitutions(declaration.name));
	}

	static function hasMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>, name:String):Bool {
		for (entry in metadata)
			if (entry.name == name)
				return true;
		return false;
	}

	static function validateStructPropertyMetadata(classDecl:AstClass, isValue:Bool, isNativeValue:Bool):Void {
		for (metadata in classDecl.metadata)
			if (metadata.name == "flat" || metadata.name == "portable") {
				if (metadata.arguments.length != 0)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, '@:${metadata.name} does not accept arguments',
						metadata.span);
				if (!isValue && !isNativeValue)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'@:${metadata.name} may only assert a value struct layout', metadata.span);
			}
	}

	function validateRepresentationMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>, isValue:Bool):Bool {
		var hasRepresentation = false;
		for (entry in metadata)
			if (entry.name == "repr") {
				if (hasRepresentation)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, 'Duplicate @:repr metadata', entry.span);
				hasRepresentation = true;
				if (entry.arguments.length != 1)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, '@:repr requires exactly one string argument',
						entry.span);
				var representation:Null<String> = null;
				switch entry.arguments[0] {
					case StringLiteral(value, _):
						representation = value;
					case _:
						BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, '@:repr requires exactly one string argument',
							entry.span);
				}
				if (representation == null)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, '@:repr requires exactly one string argument',
						entry.span);
				if (representation != "C")
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
						'Unsupported native representation "$representation"', entry.span);
				if (!isValue)
					BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH, '@:repr("C") requires @:value', entry.span);
			}
		return hasRepresentation;
	}

	function methodSignature(method:AstFunction, owner:String, ?substitutions:Map<String, CompilerType>):TypedFunction {
		var argumentTypes = bodyTyper.argumentTypesOf(method, substitutions),
			arguments = [for (index in 0...method.arguments.length)
				{
					name: method.arguments[index].name, type: argumentTypes[index]
				}],
			result = substitutions == null ? bodyTyper.functionResultType(method,
				method.span) : session.declarations.types.resultType(method, substitutions);
		for (argument in arguments)
			if (NativeLayout.containsUnsupportedRuntimeValueType(argument.type))
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Native layout types cannot be passed by value in function "${owner}.${method.name}" yet',
					method.span);
		if (NativeLayout.containsUnsupportedRuntimeValueType(result))
			BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Native layout types cannot be returned by value from function "${owner}.${method.name}" yet',
				method.span);
		return {
			name: owner + "." + method.name,
			role: UserFunction,
			owner: owner,
			isStatic: method.isStatic,
			isConstructor: method.name == "new",
			arguments: arguments,
			result: result,
			dispatchEntry: method.name == "new" || !DefaultArguments.hasDispatchEntry(method.arguments,
				[for (argument in arguments) argument.type], session.relations)
				? null : DefaultArguments.dispatchName(owner
				+ "." + method.name),
			statements: [],
			cells: [],
			cellCaptures: [],
			span: method.span
		};
	}

	function prependInstanceInitializers(method:TypedFunction, className:String, fields:Array<TypedField>,
			?receiverType:CompilerType):TypedFunction {
		var statements = instanceInitializerStatements(fields, className, receiverType);
		return {
			name: method.name,
			role: method.role,
			origin: method.origin,
			originKind: method.originKind,
			typeArguments: method.typeArguments,
			owner: method.owner,
			physicalOwner: method.physicalOwner,
			isStatic: method.isStatic,
			isConstructor: method.isConstructor,
			isInline: method.isInline,
			isKept: method.isKept,
			isExposed: method.isExposed,
			arguments: method.arguments,
			result: method.result,
			dispatchEntry: method.dispatchEntry,
			statements: statements.concat(method.statements),
			cells: method.cells,
			cellCaptures: method.cellCaptures,
			span: method.span,
			warnings: method.warnings
		};
	}

	static function instanceInitializerStatements(fields:Array<TypedField>, className:String,
			?receiverType:CompilerType):Array<TypedStatement> {
		var statements:Array<TypedStatement> = [];
		for (field in fields) {
			var initializer = field.initializer;
			if (initializer == null)
				throw new InternalError('Missing initializer for "$className.${field.name}"');
			statements.push(TFieldAssign(new TypedExpression(TLocal("this"),
				receiverType == null ? TInstance(NominalKind.Class, className, []) : receiverType, field.span),
				field.name, initializer, field.span));
		}
		return statements;
	}

	function validateInterfaceImplementation(classDecl:AstClass, interfaceInstance:CompilerType,
			classSubstitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		var interfaceName = switch interfaceInstance {
			case TInstance(Interface, name, _): name;
			default:
				BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER, "Implemented type must be an interface", span);
				return;
		};
		if (StructProperties.isConstraintType(interfaceInstance)) {
			var property = interfaceName == StructProperties.FLAT_TYPE_NAME ? "Flat" : "Portable",
				actual = TInstance(NominalKind.Class, classDecl.name, []);
			if (!session.relations.satisfiesConstraint(actual, interfaceInstance)) {
				var detail = session.relations.constraintFailure(actual, interfaceInstance);
				BodyTyper.fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Struct "${classDecl.name}" does not satisfy $property: $detail', span);
			}
			return;
		}
		if (!session.interfaceDecls.exists(interfaceName))
			return;
		var interfaceDecl = session.interfaceDecls.get(interfaceName),
			interfaceSubstitutions = session.representation.nominalSubstitutions(interfaceInstance);
		for (baseType in interfaceDecl.bases) {
			var baseInstance = session.declarations.resolve(baseType, interfaceDecl.span, interfaceSubstitutions),
				base = BodyTyper.inheritanceName(baseType);
			if (!session.interfaceDecls.exists(base) && !StructProperties.isConstraintType(baseInstance))
				throw new CompileError(Diagnostic.unresolved(DiagnosticCode.DECLARATION_OR_MODIFIER,
					UnresolvedNameKind.WantedInterface, base, span));
			validateInterfaceImplementation(classDecl, baseInstance, classSubstitutions, span);
		}
		InterfaceProperties.validateImplementation(session, bodyTyper, classDecl, interfaceDecl,
			interfaceSubstitutions);
		for (method in interfaceDecl.methods) {
			// The accessors its variables and properties imply: the class's hidden ones are made to match
			// (`InterfaceFieldAccessors`), and a `get` or `set` side's, which the variable's check found, is checked in Haxe's words.
			var implied = AstFunctions.hasMetadata(method, InterfaceFieldAccessors.GENERATED);
			if (implied && InterfaceFieldAccessors.isHiddenAccessor(method.name))
				continue;
			var implementation = bodyTyper.findMethod(classDecl.name, method.name);
			if (method.isDynamic == true && (implementation == null || implementation.isStatic)) {
				var variable = MemberAccess.classField(session, classDecl.name, method.name, false);
				if (variable != null)
					BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
						'Field ${method.name} has different property access than in $interfaceName (${InterfaceProperties.kindOf(variable.field)} should be dynamic method)',
						InterfaceProperties.nameSpan(variable.field.span, method.name));
				BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
					'Field ${method.name} needed by $interfaceName is missing',
					InterfaceProperties.classNameSpan(classDecl));
			}
			if (implementation == null || implementation.isStatic)
				BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
					'${classDecl.isStruct == true ? "Struct" : "Class"} "${classDecl.name}" does not implement "$interfaceName.${method.name}"',
					span);
			var implementationName = implementation.owner + "." + method.name,
				implementationMethod = session.signatures.get(implementationName);
			if (implementationMethod != null) {
				var isDynamic = DynamicMethods.isDynamic(session, implementationMethod, implementation.owner),
					expectsDynamic = method.isDynamic == true;
				if (expectsDynamic && !MemberAccess.isPublicMethod(session, implementation.owner, method.name))
					BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
						'Field ${method.name} should be public as requested by $interfaceName',
						InterfaceProperties.methodNameSpan(implementationMethod));
				if (isDynamic != expectsDynamic) {
					var actualKind = isDynamic ? "dynamic method" : "method",
						expectedKind = expectsDynamic ? "dynamic method" : "method";
					BodyTyper.fail(DiagnosticCode.DECLARATION_OR_MODIFIER,
						'Field ${method.name} has different property access than in $interfaceName ($actualKind should be $expectedKind)',
						InterfaceProperties.methodNameSpan(implementationMethod));
				}
			}
			var implementationSubstitutions = classSubstitutions;
			if (method.isDynamic == true && implementation.owner != classDecl.name) {
				var instance = TInstance(Class, classDecl.name,
					[for (parameter in classDecl.typeParameters) classSubstitutions.get(parameter)]),
					projected = session.declarations.inheritance.project(instance, implementation.owner);
				if (projected != null)
					implementationSubstitutions = session.representation.nominalSubstitutions(projected);
			}
			if (implementationMethod == null
				|| !sameSignature(implementationMethod, method, implementationSubstitutions, interfaceSubstitutions)) {
				if ((implied || method.isDynamic == true) && implementationMethod != null)
					BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
						'Field ${method.name} has different type than in $interfaceName',
						InterfaceProperties.methodNameSpan(implementationMethod));
				BodyTyper.fail(DiagnosticCode.TYPE_CONSTRAINT,
					'Method "${classDecl.name}.${method.name}" does not match interface "$interfaceName"',
					span);
			}
		}
	}

	function sameSignature(left:AstFunction, right:AstFunction, ?leftSubstitutions:Map<String, CompilerType>,
			?rightSubstitutions:Map<String, CompilerType>):Bool {
		if (right.isDynamic == true) {
			var leftParameters = BodyTyper.functionTypeParameters(left),
				rightParameters = BodyTyper.functionTypeParameters(right);
			if (leftParameters.length != rightParameters.length)
				return false;
			if (leftParameters.length > 0) {
				leftSubstitutions = leftSubstitutions == null
					? [] : [for (name => type in leftSubstitutions) name => type];
				rightSubstitutions = rightSubstitutions == null
					? [] : [for (name => type in rightSubstitutions) name => type];
				for (index in 0...leftParameters.length) {
					var parameter = TTypeParameter(right.name, rightParameters[index]);
					leftSubstitutions.set(leftParameters[index], parameter);
					rightSubstitutions.set(rightParameters[index], parameter);
				}
			}
		}
		if (left.arguments.length != right.arguments.length
			|| !TypeRelations.equals(session.declarations.types.resultType(left, leftSubstitutions),
			session.declarations.types.resultType(right, rightSubstitutions)))
			return false;
		// Haxe compares the optional flags too (`Not_matching_optional`), and `?x:Int` is `Null<Int>`.
		var leftArguments = session.declarations.types.argumentTypes(left, leftSubstitutions),
			rightArguments = session.declarations.types.argumentTypes(right, rightSubstitutions);
		for (i in 0...left.arguments.length)
			if (AstPredicates.isOptionalArgument(left.arguments[i])
				!= AstPredicates.isOptionalArgument(right.arguments[i])
				|| !TypeRelations.equals(DeclarationIndex.comparedArgumentType(leftArguments[i], session.relations),
				DeclarationIndex.comparedArgumentType(rightArguments[i], session.relations)))
				return false;
		return true;
	}

	static function rejectNativeBinding(fn:compiler.syntax.Ast.AstFunction, name:String):Void {
		if (fn.metadata != null)
			for (entry in fn.metadata)
				if (entry.name == "cNative")
					BodyTyper.fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
						'@:${entry.name} binds only an extern function; "$name" has a body, which would run instead',
						entry.span);
	}
}
