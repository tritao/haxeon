package compiler.types.typing;

import compiler.semantic.SemanticProgram;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.NativeLayout;
import compiler.semantic.DeclarationLifecycle.DeclarationStage;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstFunction;
import compiler.Source.SourceSpan;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.types.StructProperties;
import compiler.types.typing.TypingMetrics.MeasuredTypedProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.NativeConvention;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedInterface;
import compiler.types.TypedAst.TypedNative;
import compiler.types.TypedAst.TypedNativeLayout;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.analysis.Scope;
import compiler.compilation.AllocationMeter;

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

	public function typeProgramMeasured(semantic:SemanticProgram, selected:Null<Map<String, Bool>>, requireMain:Bool, entryPoint:Null<String>,
			?cachedMetadata:TypedProgram, ?facts:compiler.semantic.ProgramFacts, ?retainedOwners:Map<String, Bool>):MeasuredTypedProgram {
		var allocationAtStart = AllocationMeter.sample();
		var startedAt = Sys.time() * 1000.0;
		semantic.lifecycle.requireAtLeast(SignatureTyped);
		session.bindSemantic(semantic);
		if (cachedMetadata != null)
			bindCachedNativeLayouts(cachedMetadata.classes);
		var program = semantic.program;
		for (decl in program.enumAbstracts) {
			var emptySubstitutions:Map<String, CompilerType> = [];
			var underlying = session.declarations.resolve(decl.underlying, null, emptySubstitutions);
			for (value in decl.values)
				bodyTyper.coerce(bodyTyper.typeExpression(value.value, new Scope(), underlying), underlying,
					'enum abstract value "${decl.name}.${value.name}"', "E1002");
		}
		session.bindNominalDeclarations();
		for (declaration in program.enums) validateEnumConformance(declaration);
		bodyTyper.expressionTyper.prepareNativeTypeAnnotations(program);
		for (alias in program.aliases) {
			if (alias.typeParameters.length == 0) {
				var aliasType = bodyTyper.lowerType(alias.type);
				bodyTyper.registerAnonymousTypes(aliasType);
			}
		}
		var typedNatives:Array<TypedNative> = cachedMetadata == null ? [] : cachedMetadata.natives;
		if (cachedMetadata == null)
			for (fn in program.functions) {
				if (session.externals.exists(fn.name))
					BodyTyper.fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
				if (fn.isExtern == true)
					typedNatives.push(externTyper.typeExtern(fn));
			}
		if (cachedMetadata == null)
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
		if (cachedMetadata == null)
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
		if (cachedMetadata == null) {
			// A native binding replaces a function's body, so only an extern function can carry one;
			// on any other function the body would silently run instead of the native.
			for (fn in program.functions)
				if (fn.isExtern != true)
					rejectNativeBinding(fn, fn.name);
			for (classDecl in program.classes)
				if (classDecl.isExtern != true && externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null)
					for (method in classDecl.methods)
						rejectNativeBinding(method, classDecl.name + "." + method.name);
			for (abstractDecl in program.abstracts)
				if (abstractDecl.isExtern != true)
					for (method in abstractDecl.methods)
						rejectNativeBinding(method, abstractDecl.name + "." + method.name);
		}
		for (native in typedNatives)
			switch native.convention {
				case CNative(_):
					session.cNativeFunctions.set(native.name, true);
				case HashLinkNative:
			}
		var setupDoneAt = Sys.time() * 1000.0;
		var allocationAfterSetup = AllocationMeter.sample();
		// With the facts of `SemanticAssembly` there is nothing to infer: they are about this same program.
		if (facts == null) {
			bodyTyper.inferNoReturnFunctions();
			session.inferPureFunctions();
		} else {
			bodyTyper.useNoReturnFunctions(facts.noReturn);
			session.usePureFunctions(facts.pure);
		}
		var noReturnDoneAt = Sys.time() * 1000.0;
		var allocationAfterNoReturn = AllocationMeter.sample();
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
			if (main.arguments.length != 0 || ((switch (bodyTyper.lowerType(main.result)) { case TInt: false; default: true; }) && (switch (bodyTyper.lowerType(main.result)) { case TVoid: false; default: true; })))
				throw 'Executable entry point "${entryPoint == null ? main.name : entryPoint}" must take no arguments and return Int or Void';
		}
		var typedEnums:Array<TypedEnum> = cachedMetadata == null ? [
			for (enumDecl in program.enums)
				{
					name: enumDecl.name,
					equatable: DeclaredConformance.has(session, TInstance(NominalKind.Enum, enumDecl.name, []), "Equatable"),
					hashable: DeclaredConformance.has(session, TInstance(NominalKind.Enum, enumDecl.name, []), "Hashable"),
					metadata: enumDecl.metadata,
					cases: [
						for (caseDecl in enumDecl.cases)
							{
								name: caseDecl.name,
								metadata: caseDecl.metadata,
								params: [for (param in caseDecl.params) bodyTyper.erasedEnumParameter(enumDecl, param)],
								span: caseDecl.span
							}
					],
					span: enumDecl.span
				}
		] : cachedMetadata.enums, typedInterfaces:Array<TypedInterface> = cachedMetadata == null ? [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: [
						for (base in interfaceDecl.bases)
							if (!StructProperties.isConstraintSyntax(base)) BodyTyper.inheritanceName(base)
					],
					methods: [
						for (method in interfaceDecl.methods)
							{
								name: method.name,
								arguments: [
									for (argument in method.arguments)
										session.representation.resolveMethodArgument(TInstance(NominalKind.Interface, interfaceDecl.name,
											[for (_ in interfaceDecl.typeParameters) TDynamic]),
											interfaceDecl.name, argument)
											.physical],
								result: erasureType(interfaceDecl, method.result, method.span)
							}
					]
				}
			] : cachedMetadata.interfaces, typedClasses:Array<TypedClass> = cachedMetadata == null ? [
			for (classDecl in program.classes)
				if (classDecl.isExtern != true
					&& externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null) typeClass(classDecl, selected, true)
			] : refreshCachedClasses(program.classes, cachedMetadata.classes, selected), typedFunctions:Array<TypedFunction> = [];
		if (cachedMetadata != null) {
			if (retainedOwners == null) retainedOwners = [];
			session.representation.restoreGenericOwnerAliases(cachedMetadata.genericOwnerAliases, retainedOwners);
			for (cached in typedClasses)
				if (cached.specializationOrigin != null && cached.specializationArguments != null
					&& retainedOwners.exists(cached.name) && session.classDecls.exists(cached.specializationOrigin))
					session.representation.genericOwner(TInstance(NominalKind.Class, cached.specializationOrigin, cached.specializationArguments));
			typedClasses = [for (cached in typedClasses) if (cached.specializationOrigin == null) cached];
		}
		if (cachedMetadata == null)
			for (enumDecl in typedEnums)
				for (caseDecl in enumDecl.cases)
					for (parameter in caseDecl.params)
						if (NativeLayout.containsNativeLayoutType(parameter))
							BodyTyper.fail("E1022", 'Native layout types cannot be stored in a Haxe enum yet', caseDecl.span);
		if (cachedMetadata == null)
			for (interfaceIndex in 0...typedInterfaces.length) {
				var interfaceDecl = typedInterfaces[interfaceIndex],
					parsed = program.interfaces[interfaceIndex];
				for (methodIndex in 0...interfaceDecl.methods.length) {
					var method = interfaceDecl.methods[methodIndex],
						parsedMethod = parsed.methods[methodIndex];
					for (argument in method.arguments)
						if (NativeLayout.containsNativeLayoutType(argument))
							BodyTyper.fail("E1022", 'Native layout types cannot be passed by value in an interface yet', parsedMethod.span);
					if (NativeLayout.containsNativeLayoutType(method.result))
						BodyTyper.fail("E1022", 'Native layout types cannot be returned by value in an interface yet', parsedMethod.span);
				}
			}
		if (cachedMetadata == null) {
			typedClasses = layoutNativeClasses(typedClasses);
			typedClasses = typeClassBodies(program.classes, typedClasses, selected);
		} else {
			bindCachedNativeLayouts(typedClasses);
		}
		var metadataDoneAt = Sys.time() * 1000.0;
		var allocationAfterMetadata = AllocationMeter.sample();
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
		// Field and signature types can request owners without a construction expression. A
		// generated owner's fields and methods can request further owners, so drain to a fixed point.
		assembler.registerProgramTypes(typedFunctions, typedClasses, typedInterfaces, typedEnums, typedNatives);
		var ownerDeclarations = [for (declaration in program.classes) declaration.name => declaration], ownerIndex = 0, generatedIndex = 0;
		var keyPaths = new KeyPathRuntime(session, typedClasses);
		while (true) {
			var pathHelpers = keyPaths.drain();
			for (helper in pathHelpers) typedFunctions.push(helper);
			if (pathHelpers.length > 0) assembler.registerProgramTypes(pathHelpers, [], [], [], []);
			while (generatedIndex < session.closureConversion.generatedFunctionCount()) {
				var fn = session.closureConversion.generatedFunction(generatedIndex++);
				typedFunctions.push(fn);
				assembler.registerProgramTypes([fn], [], [], [], []);
			}
			if (ownerIndex >= session.representation.genericOwnerRequestCount()) break;
			var request = session.representation.genericOwnerRequest(ownerIndex++), declaration = ownerDeclarations.get(request.origin);
			if (declaration == null) throw 'Missing generic owner declaration "${request.origin}"';
			var specialized = typeClass(declaration, null, false, request);
			typedClasses.push(specialized);
			for (method in specialized.methods) typedFunctions.push(method);
			assembler.registerProgramTypes(specialized.methods, [specialized], [], [], []);
		}
		for (cache in keyPaths.newClasses) typedClasses.push(cache);
		var nativeTypeDescriptors = bodyTyper.expressionTyper.nativeTypeDescriptors();
		for (codec in WireCodecGenerator.generate(session, typedClasses, typedEnums))
			typedFunctions.push(codec);
		for (codec in WireCodecGenerator.generateJson(session, typedClasses, typedEnums))
			typedFunctions.push(codec);
		// Reflection can expose a field as Dynamic without a source-level enum conversion.
		// Keep the concrete enum operations available for those raw runtime descriptors.
		for (classDecl in typedClasses) for (field in classDecl.fields) {
			var origin = classDecl.methods.length > 0 ? classDecl.methods[0].name : typedFunctions.length > 0 ? typedFunctions[0].name : null;
			if (origin != null) EnumDynamicBox.requestReflectedTypes(session, field.type, origin, field.span);
		}
		// Native signatures can expose a typed enum (including a container element) as Dynamic.
		if (typedFunctions.length > 0) for (native in typedNatives) {
			var owner = typedFunctions[0];
			for (argument in native.arguments) EnumDynamicBox.requestReflectedTypes(session, argument, owner.name, owner.span);
			EnumDynamicBox.requestReflectedTypes(session, native.result, owner.name, owner.span);
		}
		// Equality and hash bodies can request each other, including through handwritten enum methods.
		var equalities:Map<String, TypedFunction> = [], hashes:Map<String, TypedFunction> = [], enumMethods:Map<String, TypedFunction> = [],
			enumAdapters:Map<String, TypedClass> = [];
		while (true) {
			var before = Lambda.count(session.valueEqualityRequests) + Lambda.count(session.enumEqualityRequests) + Lambda.count(session.hashRequests)
				+ Lambda.count(session.enumMethodRequests) + Lambda.count(session.enumInterfaceAdapters);
			for (adapter in EnumInterfaceAdapter.generate(session)) enumAdapters.set(adapter.name, adapter);
			for (hash in HashGenerator.generate(session, bodyTyper)) hashes.set(hash.name, hash);
			for (equality in ValueEqualityGenerator.generate(session, bodyTyper.expressionTyper.compareKnownValues)) equalities.set(equality.name, equality);
			for (equality in EnumEqualityGenerator.generate(session, bodyTyper)) equalities.set(equality.name, equality);
			for (method in EnumConformanceMethods.generate(session, bodyTyper)) enumMethods.set(method.name, method);
			if (before == Lambda.count(session.valueEqualityRequests) + Lambda.count(session.enumEqualityRequests) + Lambda.count(session.hashRequests)
				+ Lambda.count(session.enumMethodRequests) + Lambda.count(session.enumInterfaceAdapters)) break;
		}
		var adapterNames = [for (name in enumAdapters.keys()) name];
		adapterNames.sort(Reflect.compare);
		for (name in adapterNames) {
			var adapter = enumAdapters.get(name);
			typedClasses.push(adapter);
			for (method in adapter.methods) typedFunctions.push(method);
		}
		var enumMethodNames = [for (name in enumMethods.keys()) name];
		enumMethodNames.sort(Reflect.compare);
		for (name in enumMethodNames) typedFunctions.push(enumMethods.get(name));
		var hashNames = [for (name in hashes.keys()) name];
		hashNames.sort(Reflect.compare);
		for (name in hashNames) typedFunctions.push(hashes.get(name));
		var equalityNames = [for (name in equalities.keys()) name];
		equalityNames.sort(Reflect.compare);
		for (name in equalityNames) typedFunctions.push(equalities.get(name));
		assembler.registerProgramTypes(typedFunctions, typedClasses, typedInterfaces, typedEnums, typedNatives);
		var bodiesDoneAt = Sys.time() * 1000.0;
		var allocationAfterBodies = AllocationMeter.sample();
		semantic.lifecycle.advanceAll(BodyTyped);
		var bodyTransitionDoneAt = Sys.time() * 1000.0;
		var result:TypedProgram = assembler.assemble(typedEnums, typedInterfaces, typedClasses, typedFunctions, typedNatives, nativeTypeDescriptors);
		var assemblyDoneAt = Sys.time() * 1000.0;
		var allocationAfterAssembly = AllocationMeter.sample();
		semantic.lifecycle.advanceAll(Finalized);
		var finalizationDoneAt = Sys.time() * 1000.0;
		var typedRuntimeDependencies = assembler.runtimeDependencies();
		var allocationAfterFinalize = AllocationMeter.sample();
		return {
			program: result,
			runtimeDependencies: typedRuntimeDependencies,
			purityQueries: session.purityQueries,
			inlineConstantDependencies: session.inlineConstantDependencies,
			noReturnQueries: session.noReturnQueries,
			metrics: {
				allocationPhases: [
					AllocationMeter.delta("typer-setup", allocationAtStart, allocationAfterSetup),
					AllocationMeter.delta("typer-no-return", allocationAfterSetup, allocationAfterNoReturn),
					AllocationMeter.delta("typer-metadata", allocationAfterNoReturn, allocationAfterMetadata),
					AllocationMeter.delta("typer-bodies", allocationAfterMetadata, allocationAfterBodies),
					AllocationMeter.delta("typer-assembly", allocationAfterBodies, allocationAfterAssembly),
					AllocationMeter.delta("typer-finalize", allocationAfterAssembly, allocationAfterFinalize)
				],
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

	function refreshCachedClasses(parsed:Array<AstClass>, cached:Array<TypedClass>, selected:Null<Map<String, Bool>>):Array<TypedClass> {
		if (selected == null)
			return cached;
		var parsedByName = [for (decl in parsed) decl.name => decl];
		// A class is refreshed when a selected function is named under it. Checking that against every selected name for
		// every class is quadratic (millions of string concatenations in a large program), so collect the dotted prefixes
		// of the selected names once: a class is changed when its name is one of them.
		var owners:Map<String, Bool> = [];
		for (name in selected.keys()) {
			var dot = name.indexOf(".");
			while (dot >= 0) {
				owners.set(name.substr(0, dot), true);
				dot = name.indexOf(".", dot + 1);
			}
		}
		return [
			for (cachedClass in cached) {
				var changed = owners.exists(cachedClass.name);
				if (!changed || !parsedByName.exists(cachedClass.name)) cachedClass else {
					var refreshed = typeClass(parsedByName.get(cachedClass.name), selected),
						cachedMethods = [for (method in cachedClass.methods) method.name => method];
					var methods = [
						for (method in refreshed.methods)
							selected.exists(method.name) ? method : cachedMethods.exists(method.name) ? cachedMethods.get(method.name) : method
					];
					{
						name: refreshed.name,
						genericParameters: refreshed.genericParameters,
						isValue: refreshed.isValue,
						isFlat: refreshed.isFlat,
						isPortable: refreshed.isPortable,
						isNativeValue: refreshed.isNativeValue,
						nativeLayouts: cachedClass.nativeLayouts,
						base: refreshed.base,
						interfaces: refreshed.interfaces,
						fields: refreshed.fields,
						methods: methods,
						span: refreshed.span
					};
				}
			}
		];
	}

	function bindCachedNativeLayouts(classes:Array<TypedClass>):Void
		for (classDecl in classes)
			if (classDecl.isNativeValue || classDecl.isFlat)
				for (layout in classDecl.nativeLayouts)
					if (layout.target == session.nativeAbiTarget)
						session.nativeLayoutsByName.set(classDecl.name, layout);

	function typeClass(classDecl:AstClass, selected:Null<Map<String, Bool>>, deferMethodBodies:Bool = false,
			?specialization:compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation):TypedClass {
		var isStruct = classDecl.isStruct == true,
			requestedValue = isStruct || hasMetadata(classDecl.metadata, "value"),
			isNativeValue = validateRepresentationMetadata(classDecl.metadata, requestedValue),
			isValue = requestedValue && !isNativeValue;
		validateStructPropertyMetadata(classDecl, isValue, isNativeValue);
		if (isStruct && isNativeValue)
			BodyTyper.fail("E1022", 'Struct "${classDecl.name}" does not use @:repr; native layout is inferred from its fields', classDecl.span);
		if (isStruct && classDecl.typeParameters.length > 0)
			BodyTyper.fail("E1022", 'Generic struct "${classDecl.name}" is not supported yet', classDecl.span);
		if (isValue)
			validateFiniteValueLayout(classDecl, [], []);
		if ((isValue || isNativeValue) && classDecl.base != null)
			BodyTyper.fail("E1022", 'Value class "${classDecl.name}" cannot extend another class', classDecl.span);
		if ((isValue && !isStruct || isNativeValue) && classDecl.interfaces.length > 0)
			BodyTyper.fail("E1022", 'Value class "${classDecl.name}" cannot implement interfaces', classDecl.span);
		if (isNativeValue && classDecl.typeParameters.length > 0)
			BodyTyper.fail("E1022", 'Native value record "${classDecl.name}" cannot be generic', classDecl.span);
		if (isNativeValue) {
			for (field in classDecl.fields) {
				if (field.isStatic)
					BodyTyper.fail("E1022", 'Native value record "${classDecl.name}" cannot declare static fields', field.span);
				if (field.initializer != null)
					BodyTyper.fail("E1022", 'Native value field "${classDecl.name}.${field.name}" cannot have an initializer', field.span);
			}
			for (method in classDecl.methods)
				if (!method.isStatic)
					BodyTyper.fail("E1022", 'Native value record "${classDecl.name}" cannot declare instance methods or constructors', method.span);
		}
		var fields:Array<TypedField> = [],
			fieldNames:Map<String, Bool> = [],
			erasedSubstitutions = specialization == null ? session.representation.erasedNominalSubstitutions(classDecl.name) : specialization.substitutions;
		for (field in classDecl.fields) {
			if (specialization != null && field.isStatic)
				continue;
			if (fieldNames.exists(field.name))
				BodyTyper.fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			if (field.isInline && !field.isStatic)
				BodyTyper.fail("E1002", 'Inline field "${classDecl.name}.${field.name}" must be static', field.span);
			if (field.isInline && field.initializer == null)
				BodyTyper.fail("E1002", 'Inline field "${classDecl.name}.${field.name}" requires an initializer', field.span);
			var type = session.representation.physicalType(session.declarations.resolvedFieldType(classDecl.name, field), field.span, erasedSubstitutions);
			if ((switch (type) { case TVoid: true; default: false; }))
				BodyTyper.fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			if (!requestedValue && !isNativeValue && NativeLayout.containsUnsupportedRuntimeValueType(type))
				BodyTyper.fail("E1022", 'Native layout types can only appear in value structs or native value record fields', field.span);
			var initializer:Null<TypedExpression> = null,
				inlineValue:Null<TypedExpression> = null,
				parsedInitializer = field.initializer;
			if (parsedInitializer != null) {
				if (field.isInline) {
					var resolved = bodyTyper.resolveInlineConstant(classDecl.name, field.name, field.span);
					if (resolved == null)
						BodyTyper.fail("E1002", 'Unable to resolve inline constant "${classDecl.name}.${field.name}"', field.span);
					initializer = resolved.initializer;
					inlineValue = resolved.value;
				} else {
					var initializerContext = bodyTyper.enterBody((specialization == null ? classDecl.name : specialization.name) + ".__init",
						erasedSubstitutions, specialization == null ? null : classDecl.name),
						scope = new Scope();
					if (!field.isStatic)
						scope.defineReceiver(session.representation.receiverType(classDecl.name, erasedSubstitutions), field.span);
					try {
						initializer = bodyTyper.coerce(EnumAbstractHints.typed(session, EnumAbstractHints.named(session, field.type), parsedInitializer,
							() -> bodyTyper.typeExpression(parsedInitializer, scope, type)),
							type, (field.isStatic ? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"'), "E1002");
					} catch (error:Dynamic) {
						bodyTyper.leaveBody(initializerContext);
						throw error;
					}
					bodyTyper.leaveBody(initializerContext);
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
				span: field.span
			});
		}
		var propertyFacts = StructProperties.evaluate(session.declarations, TInstance(NominalKind.Class, classDecl.name, []));
		for (metadata in classDecl.metadata) {
			if (metadata.name == "flat" && !propertyFacts.flat)
				BodyTyper.fail("E1022", 'Struct "${classDecl.name}" asserts @:flat but field "${propertyFacts.flatPath}" is not Flat', metadata.span);
			if (metadata.name == "portable" && !propertyFacts.portable)
				BodyTyper.fail("E1022", 'Struct "${classDecl.name}" asserts @:portable but field "${propertyFacts.portablePath}" is not Portable',
					metadata.span);
		}
		var classSemanticSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			classSemanticSubstitutions.set(parameter, TTypeParameter(classDecl.name, parameter));
		for (interfaceType in classDecl.interfaces) {
			var interfaceInstance = session.declarations.resolve(interfaceType, classDecl.span, classSemanticSubstitutions),
				interfaceName = BodyTyper.inheritanceName(interfaceType);
			if (!session.interfaceDecls.exists(interfaceName) && !StructProperties.isConstraintType(interfaceInstance))
				BodyTyper.fail("E1007", 'Unknown interface "$interfaceName"', classDecl.span);
			validateInterfaceImplementation(classDecl, interfaceInstance, classSemanticSubstitutions, classDecl.span);
		}
		var declaredType = TInstance(NominalKind.Class, classDecl.name,
			[for (parameter in classDecl.typeParameters) TTypeParameter(classDecl.name, parameter)]);
		validateObservable(classDecl, declaredType, classSemanticSubstitutions, isValue, isNativeValue);
		validateDeclaredConformance(classDecl, declaredType, classSemanticSubstitutions);
		var parsedBase = classDecl.base, baseName:Null<String> = null;
		if (parsedBase != null) {
			baseName = BodyTyper.inheritanceName(parsedBase);
			var baseType = session.declarations.resolve(parsedBase, classDecl.span, erasedSubstitutions),
				baseSpecialization = session.representation.genericOwner(baseType);
			if (baseSpecialization != null) baseName = baseSpecialization.name;
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
			methods: typeClassMethods(classDecl, fields, selected, deferMethodBodies, erasedSubstitutions, specialization),
			span: classDecl.span
		};
	}

	function validateObservable(classDecl:AstClass, declaredType:CompilerType,
			classSemanticSubstitutions:Map<String, CompilerType>, isValue:Bool, isNativeValue:Bool):Void {
		if (!DeclaredConformance.has(session, declaredType, "Observable"))
			return;
		// Observable field access is generated after typing. Its per-object source is
		// therefore an implicit module dependency even when user code imports none of
		// the reactive runtime classes.
		session.runtimeDependencyTracker.record(classDecl.name + ".new", "haxeon.reactive.ObservableSource");
		session.runtimeDependencyTracker.record(classDecl.name + ".new", "haxeon.reactive.ReactiveRuntime");
		if (isValue || isNativeValue)
			BodyTyper.fail("E1025", 'Observable conformance is only supported on classes with identity: "${classDecl.name}"', classDecl.span);
		if (classDecl.base != null) {
			var baseType = session.declarations.resolve(classDecl.base, classDecl.span, classSemanticSubstitutions);
			if (!DeclaredConformance.has(session, baseType, "Observable"))
				BodyTyper.fail("E1025", 'Observable class "${classDecl.name}" must extend an Observable base class', classDecl.span);
		}
		for (field in DiffIntrinsics.storedFields(classDecl)) {
			var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(classDecl.name, field), field.span,
				classSemanticSubstitutions);
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
		if (DeclaredConformance.has(session, declaredType, "Equatable")) {
			var hasEquals = false, hasHash = false;
			for (method in classDecl.methods)
				if (method.name == "equals") {
					hasEquals = true;
					if (method.isStatic || method.arguments.length != 1
						|| !TypeRelations.equals(session.declarations.resolve(method.arguments[0].type, method.span, classSemanticSubstitutions), declaredType)
						|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, classSemanticSubstitutions), TBool))
						BodyTyper.fail("E1003", 'Method "${classDecl.name}.equals" must have signature equals(other:${classDecl.name}):Bool', method.span);
				} else if (method.name == "hash" && DeclaredConformance.has(session, declaredType, "Hashable")) {
					hasHash = true;
					if (method.isStatic || method.arguments.length != 0
						|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, classSemanticSubstitutions), TInt))
						BodyTyper.fail("E1003", 'Method "${classDecl.name}.hash" must have signature hash():Int', method.span);
				}
			var inheritedEquals = DiffIntrinsics.conformanceMethod(session, declaredType, "equals"),
				inheritedHash = DiffIntrinsics.conformanceMethod(session, declaredType, "hash");
			hasEquals = inheritedEquals != null;
			hasHash = inheritedHash != null;
			if (inheritedEquals != null && inheritedEquals.declaration.name != classDecl.name) {
				var method = inheritedEquals.method, substitutions = session.representation.nominalSubstitutions(inheritedEquals.type);
				if (method.isStatic || method.arguments.length != 1
						|| !TypeRelations.equals(session.declarations.resolve(method.arguments[0].type, method.span, substitutions), inheritedEquals.type)
						|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, substitutions), TBool))
					BodyTyper.fail("E1003", 'Method "${inheritedEquals.declaration.name}.equals" must have signature equals(other:${compiler.semantic.SemanticSignature.display(inheritedEquals.type)}):Bool', method.span);
			}
			if (DeclaredConformance.has(session, declaredType, "Hashable") && inheritedHash != null
					&& inheritedHash.declaration.name != classDecl.name) {
				var method = inheritedHash.method, substitutions = session.representation.nominalSubstitutions(inheritedHash.type);
				if (method.isStatic || method.arguments.length != 0
						|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, substitutions), TInt))
					BodyTyper.fail("E1003", 'Method "${inheritedHash.declaration.name}.hash" must have signature hash():Int', method.span);
			}
			if (!hasEquals)
				for (entry in DiffIntrinsics.conformanceFields(session, declaredType)) {
					var field = entry.field, fieldType = entry.type;
					if (!DeclaredConformance.supportsEquality(session, fieldType))
						BodyTyper.fail("E1025", 'Cannot synthesize Equatable for "${classDecl.name}": field "${field.name}" does not conform to Equatable', field.span);
				}
			if (DeclaredConformance.has(session, declaredType, "Hashable") && !hasHash) {
				if (hasEquals)
					BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "${classDecl.name}" with a handwritten equals; provide hash():Int', classDecl.span);
				var hashFields = DiffIntrinsics.conformanceFields(session, declaredType);
				for (entry in hashFields) {
					var field = entry.field, fieldType = entry.type;
					if (!DeclaredConformance.supportsHash(session, fieldType))
						BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "${classDecl.name}": field "${field.name}" does not conform to Hashable', field.span);
				}
				if (classDecl.isStruct != true)
					for (entry in hashFields) {
						var field = entry.field;
						if (DiffIntrinsics.isWritable(field))
							BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "${classDecl.name}": mutable field "${field.name}" must be final on a class', field.span);
					}
			}
	}
	}

	function validateEnumInterface(declaration:compiler.syntax.Ast.AstEnum, interfaceType:CompilerType, enumSubstitutions:Map<String, CompilerType>,
			requiredMethods:Map<String, Bool>):Void {
		var interfaceName = switch interfaceType {
			case TInstance(NominalKind.Interface, name, _): name;
			default:
				BodyTyper.fail("E1007", 'Enum "${declaration.name}" must implement an interface', declaration.span);
				return;
		};
		var contract = session.interfaceDecls.get(interfaceName);
		if (contract == null)
			BodyTyper.fail("E1007", 'Unknown interface "$interfaceName"', declaration.span);
		var interfaceSubstitutions = session.representation.nominalSubstitutions(interfaceType);
		for (base in contract.bases)
			validateEnumInterface(declaration, session.declarations.resolve(base, contract.span, interfaceSubstitutions), enumSubstitutions, requiredMethods);
		for (method in contract.methods) {
			requiredMethods.set(method.name, true);
			var implementation:Null<AstFunction> = null;
			if (declaration.methods != null)
				for (candidate in declaration.methods)
					if (candidate.name == method.name) implementation = candidate;
			if (implementation == null || implementation.isStatic)
				BodyTyper.fail("E1007", 'Enum "${declaration.name}" does not implement "$interfaceName.${method.name}"', declaration.span);
			if ((implementation.typeParameters != null && implementation.typeParameters.length > 0)
				|| !sameSignature(implementation, method, enumSubstitutions, interfaceSubstitutions))
				BodyTyper.fail("E1003", 'Method "${declaration.name}.${method.name}" does not match interface "$interfaceName"', implementation.span);
		}
	}

	/** Equality and hashing are properties of the enum type, not its chosen physical representation. */
	function validateEnumConformance(declaration:compiler.syntax.Ast.AstEnum):Void {
		var substitutions:Map<String, CompilerType> = [];
		for (parameter in declaration.typeParameters) substitutions.set(parameter, TTypeParameter(declaration.name, parameter));
		var requiredMethods:Map<String, Bool> = [];
		if (declaration.conformances != null) for (conformance in declaration.conformances) {
			var resolved = session.declarations.resolve(conformance, declaration.span, substitutions);
			validateEnumInterface(declaration, resolved, substitutions, requiredMethods);
		}
		var type:CompilerType = TInstance(NominalKind.Enum, declaration.name,
			[for (parameter in declaration.typeParameters) substitutions.get(parameter)]),
			equatable = DeclaredConformance.has(session, type, "Equatable"),
			hashable = DeclaredConformance.has(session, type, "Hashable"), hasEquals = false, hasHash = false;
		var hasPayload = false;
		for (constructor in declaration.cases) if (constructor.params.length > 0) hasPayload = true;
		var seenMethods:Map<String, Bool> = [];
		if (declaration.methods != null) for (method in declaration.methods) {
			if (seenMethods.exists(method.name))
				BodyTyper.fail("E1003", 'Duplicate method "${declaration.name}.${method.name}"', method.span);
			seenMethods.set(method.name, true);
			if (!hasPayload && (method.name == "equals" || method.name == "hash"))
				BodyTyper.fail("E1025", 'Nullary enum "${declaration.name}" uses tag equality and cannot override equals or hash', method.span);
			if (method.name != "equals" && method.name != "hash") {
				if (!requiredMethods.exists(method.name))
					BodyTyper.fail("E1025", 'Enum method "${declaration.name}.${method.name}" must implement a declared interface method', method.span);
				continue;
			}
			if (method.name == "equals") {
				hasEquals = true;
				if (!equatable) BodyTyper.fail("E1025", 'Enum "${declaration.name}" must declare Equatable to define equals', method.span);
				if (method.isStatic || method.arguments.length != 1 || (method.typeParameters != null && method.typeParameters.length > 0)
					|| !TypeRelations.equals(session.declarations.resolve(method.arguments[0].type, method.span, substitutions), type)
					|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, substitutions), TBool))
					BodyTyper.fail("E1003", 'Method "${declaration.name}.equals" must have signature equals(other:${declaration.name}):Bool', method.span);
			} else {
				hasHash = true;
				if (!hashable) BodyTyper.fail("E1025", 'Enum "${declaration.name}" must declare Hashable to define hash', method.span);
				if (method.isStatic || method.arguments.length != 0 || (method.typeParameters != null && method.typeParameters.length > 0)
					|| !TypeRelations.equals(session.declarations.resolve(method.result, method.span, substitutions), TInt))
					BodyTyper.fail("E1003", 'Method "${declaration.name}.hash" must have signature hash():Int', method.span);
			}
		}
		if (hashable && hasEquals && !hasHash)
			BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "${declaration.name}" with a handwritten equals; provide hash():Int', declaration.span);
		if (!equatable) return;
		for (constructor in declaration.cases) for (parameter in constructor.params) {
			var fieldType = session.representation.enumParameterType(declaration.typeParameters, parameter, type),
				field = parameter.name == null ? "payload" : parameter.name;
			if (!hasEquals && !DeclaredConformance.supportsEquality(session, fieldType))
				BodyTyper.fail("E1025", 'Cannot synthesize Equatable for "${declaration.name}": ${constructor.name}.$field does not conform to Equatable', parameter.span);
			if (hashable && !hasHash && !DeclaredConformance.supportsHash(session, fieldType))
				BodyTyper.fail("E1025", 'Cannot synthesize Hashable for "${declaration.name}": ${constructor.name}.$field does not conform to Hashable', parameter.span);
		}
	}

	/** A nullable value still contains its payload inline, so it cannot break a by-value cycle. */
	function validateFiniteValueLayout(declaration:AstClass, visiting:Array<String>, complete:Map<String, Bool>):Void {
		var cycle = visiting.indexOf(declaration.name);
		if (cycle >= 0)
			BodyTyper.fail("E1022", 'Value layout contains a by-value cycle: ${visiting.slice(cycle).concat([declaration.name]).join(" -> ")}',
				declaration.span);
		if (complete.exists(declaration.name))
			return;
		var path = visiting.concat([declaration.name]);
		for (field in declaration.fields) {
			if (field.isStatic || !DiffIntrinsics.hasStoredField(field))
				continue;
			var type = session.declarations.resolve(session.declarations.resolvedFieldType(declaration.name, field), field.span);
			validateFiniteValueField(type, path, complete);
		}
		complete.set(declaration.name, true);
	}

	function validateFiniteValueField(type:CompilerType, visiting:Array<String>, complete:Map<String, Bool>):Void {
		switch type {
			case TNullable(element): validateFiniteValueField(element, visiting, complete);
			case TAbstract(_, _, representation): validateFiniteValueField(representation, visiting, complete);
			case TInstance(NominalKind.Class, name, _) if (session.relations.isValueClass(type)):
				var nested = session.declarations.classes.get(name);
				if (nested != null)
					validateFiniteValueLayout(nested, visiting, complete);
			default:
		}
	}

	function typeClassBodies(declarations:Array<AstClass>, classes:Array<TypedClass>, selected:Null<Map<String, Bool>>):Array<TypedClass> {
		var byName:Map<String, AstClass> = [for (declaration in declarations) declaration.name => declaration];
		return [
			for (typed in classes) {
				var declaration = byName.get(typed.name);
				if (declaration == null) typed else {
					var substitutions = session.representation.erasedNominalSubstitutions(declaration.name);
					{
						name: typed.name,
						genericParameters: typed.genericParameters,
						isValue: typed.isValue,
						isFlat: typed.isFlat,
						isPortable: typed.isPortable,
						isNativeValue: typed.isNativeValue,
						nativeLayouts: typed.nativeLayouts,
						base: typed.base,
						interfaces: typed.interfaces,
						fields: typed.fields,
						methods: typeClassMethods(declaration, typed.fields, selected, false, substitutions),
						span: typed.span
					};
				}
			}
		];
	}

	function typeClassMethods(classDecl:AstClass, fields:Array<TypedField>, selected:Null<Map<String, Bool>>, deferBodies:Bool,
			substitutions:Map<String, CompilerType>, ?specialization:compiler.types.typing.TypeRepresentation.GenericOwnerRepresentation):Array<TypedFunction> {
		var typedMethods:Array<TypedFunction> = [],
			instanceInitializers:Array<TypedField> = [],
			hasConstructor = false;
		for (field in fields)
			if (!field.isStatic && field.initializer != null)
				instanceInitializers.push(field);
		for (method in classDecl.methods) {
			if (specialization != null && method.isStatic)
				continue;
			if (specialization == null && !method.isStatic && isConstrainedOwnerTemplate(classDecl.name))
				continue;
			if (BodyTyper.isGeneric(method))
				continue;
			var qualified = classDecl.name + "." + method.name,
				typeBody = !deferBodies && (specialization != null || selected == null || selected.exists(qualified)),
				typedMethod = typeBody ? bodyTyper.typeFunction(method, classDecl.name, method.isStatic,
					substitutions, specialization == null ? null : specialization.name + "." + method.name, null,
					specialization == null ? null : specialization.name, specialization == null ? null : specialization.typeArguments)
					: methodSignature(method, classDecl.name, substitutions);
			if (method.name == "new") {
				hasConstructor = true;
				if (typeBody && instanceInitializers.length > 0)
					typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers,
						specialization == null ? null : session.representation.receiverType(classDecl.name, substitutions));
			}
			typedMethods.push(typedMethod);
		}
		if (!hasConstructor
			&& (specialization != null || !isConstrainedOwnerTemplate(classDecl.name))
			&& instanceInitializers.length > 0
			&& !deferBodies
			&& (specialization != null || selected == null || selected.exists(classDecl.name + ".new")))
			typedMethods.push({
				name: (specialization == null ? classDecl.name : specialization.name) + ".new",
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
				span: classDecl.span
			});
		return typedMethods;
	}

	function isConstrainedOwnerTemplate(name:String):Bool {
		var declaration = session.classDecls.get(name);
		return declaration != null && declaration.typeParameters.length > 0
			&& declaration.typeConstraints != null && declaration.typeConstraints.length > 0;
	}

	function layoutNativeClasses(classes:Array<TypedClass>):Array<TypedClass> {
		var byName:Map<String, TypedClass> = [], layoutsByTarget:Map<String, Map<String, TypedNativeLayout>> = [], targets = [
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
		return [
			for (classDecl in classes) {
				var hasNativeLayout = classDecl.isNativeValue || classDecl.isFlat,
					nativeLayouts:Array<TypedNativeLayout> = hasNativeLayout ? [
						for (target in targets)
							requiredNativeLayout(layoutsByTarget, target, classDecl.name)
					] : [];
				if (hasNativeLayout) session.nativeLayoutsByName.set(classDecl.name,
					requiredNativeLayout(layoutsByTarget, session.nativeAbiTarget, classDecl.name));
				{
					name: classDecl.name,
					genericParameters: classDecl.genericParameters,
					isValue: classDecl.isValue,
					isFlat: classDecl.isFlat,
					isPortable: classDecl.isPortable,
					isNativeValue: classDecl.isNativeValue,
					nativeLayouts: nativeLayouts,
					base: classDecl.base,
					interfaces: classDecl.interfaces,
					fields: classDecl.fields,
					methods: classDecl.methods,
					span: classDecl.span
				}
			}
		];
	}

	static function requiredNativeLayout(layoutsByTarget:Map<String, Map<String, TypedNativeLayout>>, target:String, name:String):TypedNativeLayout {
		var layouts = layoutsByTarget.get(target);
		if (layouts == null)
			throw 'Missing native layout target "$target"';
		var layout = layouts.get(name);
		if (layout == null)
			throw 'Missing native layout for "$name" on target "$target"';
		return layout;
	}

	function computeNativeLayout(name:String, target:String, classes:Map<String, TypedClass>, layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>):TypedNativeLayout {
		var cached = layouts.get(name);
		if (cached != null)
			return cached;
		var key = target + ":" + name, declaration = classes.get(name);
		if (declaration == null || (!declaration.isNativeValue && !declaration.isFlat))
			throw 'Missing flat or native value record "$name"';
		if (visiting.exists(key))
			BodyTyper.fail("E1022", 'Flat value record "$name" contains a by-value layout cycle', declaration.span);
		visiting.set(key, true);
		var nativeDeclarations:Map<String, HxiDeclaration> = [];
		for (field in declaration.fields)
			if (!field.isStatic)
				collectNestedNativeDeclarations(field.type, target, classes, layouts, visiting, nativeDeclarations, field.span);
		var layout:TypedNativeLayout = try NativeLayout.record(target, name, [
			for (field in declaration.fields)
				if (!field.isStatic) {name: field.name, type: field.type, span: field.span}
		], nativeDeclarations, declaration.span) catch (error:Dynamic) {
			visiting.remove(key);
			BodyTyper.fail("E1022", 'Invalid flat value record "$name": ${Std.string(error)}', declaration.span);
			cast null;
		};
		visiting.remove(key);
		layouts.set(name, layout);
		return layout;
	}

	function collectNestedNativeDeclarations(type:CompilerType, target:String, classes:Map<String, TypedClass>, layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>, result:Map<String, HxiDeclaration>, span:SourceSpan):Void {
		switch type {
			case TAbstract(_, _, representation):
				collectNestedNativeDeclarations(representation, target, classes, layouts, visiting, result, span);
			case TInstance(NominalKind.NativeValue, name, arguments):
				if (arguments.length != 0)
					BodyTyper.fail("E1022", 'Generic native value field "$name" has no fixed layout', span);
				addNestedNativeDeclaration(name, target, classes, layouts, visiting, result);
			case TInstance(NominalKind.Class, name, arguments):
				if (arguments.length != 0)
					BodyTyper.fail("E1022", 'Generic struct field "$name" has no fixed layout', span);
				addNestedNativeDeclaration(name, target, classes, layouts, visiting, result);
			case _:
		}
	}

	function addNestedNativeDeclaration(name:String, target:String, classes:Map<String, TypedClass>, layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>, result:Map<String, HxiDeclaration>):Void {
		var nested = computeNativeLayout(name, target, classes, layouts, visiting),
			nestedClass = classes.get(name);
		if (nestedClass == null)
			throw 'Missing flat or native value record "$name"';
		result.set(name, NativeLayout.nestedDeclaration(name, nested, nestedClass.span));
	}

	function erasureType(declaration:compiler.syntax.Ast.AstInterface, type:compiler.syntax.Ast.AstType, span:SourceSpan):CompilerType {
		return session.representation.physicalType(type, span, session.representation.erasedNominalSubstitutions(declaration.name));
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
					BodyTyper.fail("E1022", '@:${metadata.name} does not accept arguments', metadata.span);
				if (!isValue && !isNativeValue)
					BodyTyper.fail("E1022", '@:${metadata.name} may only assert a value struct layout', metadata.span);
			}
	}

	function validateRepresentationMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>, isValue:Bool):Bool {
		var hasRepresentation = false;
		for (entry in metadata)
			if (entry.name == "repr") {
				if (hasRepresentation)
					BodyTyper.fail("E1022", 'Duplicate @:repr metadata', entry.span);
				hasRepresentation = true;
				if (entry.arguments.length != 1)
					BodyTyper.fail("E1022", '@:repr requires exactly one string argument', entry.span);
				var representation:Null<String> = null;
				switch entry.arguments[0] {
					case StringLiteral(value, _):
						representation = value;
					case _:
						BodyTyper.fail("E1022", '@:repr requires exactly one string argument', entry.span);
				}
				if (representation == null)
					BodyTyper.fail("E1022", '@:repr requires exactly one string argument', entry.span);
				if (representation != "C")
					BodyTyper.fail("E1022", 'Unsupported native representation "$representation"', entry.span);
				if (!isValue)
					BodyTyper.fail("E1022", '@:repr("C") requires @:value', entry.span);
			}
		return hasRepresentation;
	}

	function methodSignature(method:AstFunction, owner:String, ?substitutions:Map<String, CompilerType>):TypedFunction {
		var arguments = [
			for (argument in method.arguments)
				{
					name: argument.name,
					type: bodyTyper.argumentType(argument, substitutions)
				}
		], result = substitutions == null ? bodyTyper.lowerType(method.result) : session.declarations.resolve(method.result, method.span, substitutions);
		for (argument in arguments)
			if (NativeLayout.containsUnsupportedRuntimeValueType(argument.type))
				BodyTyper.fail("E1022", 'Native layout types cannot be passed by value in function "${owner}.${method.name}" yet', method.span);
		if (NativeLayout.containsUnsupportedRuntimeValueType(result))
			BodyTyper.fail("E1022", 'Native layout types cannot be returned by value from function "${owner}.${method.name}" yet', method.span);
		return {
			name: owner + "." + method.name,
			owner: owner,
			isStatic: method.isStatic,
			isConstructor: method.name == "new",
			arguments: arguments,
			result: result,
			statements: [],
			cells: [],
			cellCaptures: [],
			span: method.span
		};
	}

	function prependInstanceInitializers(method:TypedFunction, className:String, fields:Array<TypedField>, ?receiverType:CompilerType):TypedFunction {
		var statements = instanceInitializerStatements(fields, className, receiverType);
		return {
			name: method.name,
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
			statements: statements.concat(method.statements),
			cells: method.cells,
			cellCaptures: method.cellCaptures,
			span: method.span
		};
	}

	static function instanceInitializerStatements(fields:Array<TypedField>, className:String, ?receiverType:CompilerType):Array<TypedStatement> {
		var statements:Array<TypedStatement> = [];
		for (field in fields) {
			var initializer = field.initializer;
			if (initializer == null)
				throw 'Missing initializer for "$className.${field.name}"';
			statements.push(TFieldAssign(new TypedExpression(TLocal("this"), receiverType == null ? TInstance(NominalKind.Class, className, []) : receiverType, field.span), field.name,
				initializer, field.span));
		}
		return statements;
	}

	function validateInterfaceImplementation(classDecl:AstClass, interfaceInstance:CompilerType, classSubstitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		var interfaceName = switch interfaceInstance {
			case TInstance(Interface, name, _): name;
			default:
				BodyTyper.fail("E1007", "Implemented type must be an interface", span);
				return;
		};
		if (StructProperties.isConstraintType(interfaceInstance)) {
			var property = interfaceName == StructProperties.FLAT_TYPE_NAME ? "Flat" : "Portable",
				actual = TInstance(NominalKind.Class, classDecl.name, []);
			if (!session.relations.satisfiesConstraint(actual, interfaceInstance)) {
				var detail = session.relations.constraintFailure(actual, interfaceInstance);
				BodyTyper.fail("E1022", 'Struct "${classDecl.name}" does not satisfy $property: $detail', span);
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
				BodyTyper.fail("E1007", 'Unknown interface "$base"', span);
			validateInterfaceImplementation(classDecl, baseInstance, classSubstitutions, span);
		}
		for (method in interfaceDecl.methods) {
			var implementation = bodyTyper.findMethod(classDecl.name, method.name);
			if (implementation == null || implementation.isStatic)
				BodyTyper.fail("E1007",
					'${classDecl.isStruct == true ? "Struct" : "Class"} "${classDecl.name}" does not implement "$interfaceName.${method.name}"', span);
			var implementationName = implementation.owner + "." + method.name;
			if (!session.signatures.exists(implementationName)
				|| !sameSignature(BodyTyper.requiredMapValue(session.signatures, implementationName), method, classSubstitutions, interfaceSubstitutions))
				BodyTyper.fail("E1003", 'Method "${classDecl.name}.${method.name}" does not match interface "$interfaceName"', span);
		}
	}

	function sameSignature(left:AstFunction, right:AstFunction, ?leftSubstitutions:Map<String, CompilerType>,
			?rightSubstitutions:Map<String, CompilerType>):Bool {
		if (left.arguments.length != right.arguments.length
			|| !TypeRelations.equals(session.declarations.resolve(left.result, left.span, leftSubstitutions),
				session.declarations.resolve(right.result, right.span, rightSubstitutions)))
			return false;
		for (i in 0...left.arguments.length)
			if (!TypeRelations.equals(session.declarations.resolve(left.arguments[i].type, left.arguments[i].span, leftSubstitutions),
				session.declarations.resolve(right.arguments[i].type, right.arguments[i].span, rightSubstitutions)))
				return false;
		return true;
	}

	static function rejectNativeBinding(fn:compiler.syntax.Ast.AstFunction, name:String):Void {
		if (fn.metadata != null)
			for (entry in fn.metadata)
				if (entry.name == "hlNative" || entry.name == "cNative")
					BodyTyper.fail("E1021", '@:${entry.name} binds only an extern function; "$name" has a body, which would run instead', entry.span);
	}
}
