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
										erasureType(interfaceDecl, argument.type, argument.span)
								],
								result: erasureType(interfaceDecl, method.result, method.span)
							}
					]
				}
			], typedClasses:Array<TypedClass> = [
			for (classDecl in program.classes)
				if (classDecl.isExtern != true
					&& externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null) typeClass(classDecl, selected, false)
			], typedFunctions:Array<TypedFunction> = [];
		for (enumDecl in typedEnums)
			for (caseDecl in enumDecl.cases)
				for (parameter in caseDecl.params)
					if (NativeLayout.containsNativeLayoutType(parameter))
						BodyTyper.fail("E1022", 'Native layout types cannot be stored in a Haxe enum yet', caseDecl.span);
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
		// Native layouts must be available before class bodies can instantiate layout-dependent generics.
		typedClasses = layoutNativeClasses(typedClasses);
		typedClasses = [
			for (classDecl in program.classes)
				if (classDecl.isExtern != true
					&& externTyper.nativeLibrary(classDecl.name, classDecl.metadata) == null) typeClass(classDecl, selected, true)
		];
		typedClasses = layoutNativeClasses(typedClasses);
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

	function typeClass(classDecl:AstClass, selected:Null<Map<String, Bool>>, typeBodies:Bool):TypedClass {
		var requestedValue = hasMetadata(classDecl.metadata, "value"),
			isNativeValue = validateRepresentationMetadata(classDecl.metadata, requestedValue),
			isValue = requestedValue && !isNativeValue,
			isNativeUnion = hasMetadata(classDecl.metadata, "union");
		if (isNativeUnion && !isNativeValue)
			BodyTyper.fail("E1022", '@:union requires @:repr("C") on a native value record', classDecl.span);
		if ((isValue || isNativeValue) && classDecl.base != null)
			BodyTyper.fail("E1022", 'Value class "${classDecl.name}" cannot extend another class', classDecl.span);
		if ((isValue || isNativeValue) && classDecl.interfaces.length > 0)
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
			erasedSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			erasedSubstitutions.set(parameter, TDynamic);
		for (field in classDecl.fields) {
			var nativeArrayLength:Null<Int> = try NativeLayout.fixedArrayLength(field.metadata) catch (error:Dynamic) {
				BodyTyper.fail("E1022", Std.string(error), field.span);
				cast null;
			};
			if (nativeArrayLength != null && !isNativeValue)
				BodyTyper.fail("E1022", "@:array fields require a native value record", field.span);
			if (fieldNames.exists(field.name))
				BodyTyper.fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			if (field.isInline && !field.isStatic)
				BodyTyper.fail("E1002", 'Inline field "${classDecl.name}.${field.name}" must be static', field.span);
			if (field.isInline && field.initializer == null)
				BodyTyper.fail("E1002", 'Inline field "${classDecl.name}.${field.name}" requires an initializer', field.span);
			var type = session.declarations.resolve(session.declarations.resolvedFieldType(classDecl.name, field), field.span, erasedSubstitutions);
			if (type == TVoid)
				BodyTyper.fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			if (!isNativeValue && NativeLayout.containsNativeLayoutType(type))
				BodyTyper.fail("E1022", 'Native layout types can only appear in native value record fields', field.span);
			var initializer:Null<TypedExpression> = null,
				inlineValue:Null<TypedExpression> = null,
				parsedInitializer = field.initializer;
			if (parsedInitializer != null && typeBodies) {
				if (field.isInline) {
					var resolved = bodyTyper.resolveInlineConstant(classDecl.name, field.name, field.span);
					if (resolved == null)
						BodyTyper.fail("E1002", 'Unable to resolve inline constant "${classDecl.name}.${field.name}"', field.span);
					initializer = resolved.initializer;
					inlineValue = resolved.value;
				} else {
					var initializerContext = bodyTyper.enterBody(classDecl.name + ".__init", erasedSubstitutions),
						scope = new Scope();
					if (!field.isStatic)
						scope.defineReceiver(TInstance(NominalKind.Class, classDecl.name, []), field.span);
					try {
						initializer = bodyTyper.coerce(bodyTyper.typeExpression(parsedInitializer, scope, type), type,
							(field.isStatic ? 'static field "${classDecl.name}.${field.name}"' : 'field "${classDecl.name}.${field.name}"'), "E1002");
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
				type: type,
				nativeArrayLength: nativeArrayLength,
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
		var classSemanticSubstitutions:Map<String, CompilerType> = [];
		for (parameter in classDecl.typeParameters)
			classSemanticSubstitutions.set(parameter, TTypeParameter(classDecl.name, parameter));
		for (interfaceType in classDecl.interfaces) {
			var interfaceInstance = session.declarations.resolve(interfaceType, classDecl.span, classSemanticSubstitutions),
				interfaceName = BodyTyper.inheritanceName(interfaceType);
			if (!session.interfaceDecls.exists(interfaceName))
				BodyTyper.fail("E1007", 'Unknown interface "$interfaceName"', classDecl.span);
			validateInterfaceImplementation(classDecl, interfaceInstance, classSemanticSubstitutions, classDecl.span);
		}
		var typedMethods:Array<TypedFunction> = [],
			instanceInitializers:Array<TypedField> = [],
			hasConstructor = false;
		for (field in fields)
			if (!field.isStatic && field.initializer != null)
				instanceInitializers.push(field);
		for (method in classDecl.methods) {
			if (BodyTyper.isGeneric(method))
				continue;
			var qualified = classDecl.name + "." + method.name,
				typeBody = typeBodies && (selected == null || selected.exists(qualified)),
				typedMethod = typeBody ? bodyTyper.typeFunction(method, classDecl.name, method.isStatic,
					erasedSubstitutions) : methodSignature(method, classDecl.name, erasedSubstitutions);
			if (method.name == "new") {
				hasConstructor = true;
				if (typeBody && instanceInitializers.length > 0)
					typedMethod = prependInstanceInitializers(typedMethod, classDecl.name, instanceInitializers);
			}
			typedMethods.push(typedMethod);
		}
		if (typeBodies
			&& !hasConstructor
			&& instanceInitializers.length > 0
			&& (selected == null || selected.exists(classDecl.name + ".new")))
			typedMethods.push({
				name: classDecl.name + ".new",
				owner: classDecl.name,
				isStatic: false,
				isConstructor: true,
				arguments: [],
				result: TVoid,
				statements: instanceInitializerStatements(instanceInitializers, classDecl.name),
				cells: [],
				cellCaptures: [],
				span: classDecl.span
			});
		var parsedBase = classDecl.base, baseName:Null<String> = null;
		if (parsedBase != null)
			baseName = BodyTyper.inheritanceName(parsedBase);
		return {
			name: classDecl.name,
			isValue: isValue,
			isNativeValue: isNativeValue,
			isNativeUnion: isNativeUnion,
			nativeLayouts: [],
			base: baseName,
			interfaces: [
				for (interfaceType in classDecl.interfaces)
					BodyTyper.inheritanceName(interfaceType)
			],
			fields: fields,
			methods: typedMethods,
			span: classDecl.span
		};
	}

	function layoutNativeClasses(classes:Array<TypedClass>):Array<TypedClass> {
		var byName:Map<String, TypedClass> = [],
			layoutsByTarget:Map<String, Map<String, TypedNativeLayout>> = [],
			targets = ["portable-abi32", "portable-abi64"];
		if (targets.indexOf(session.nativeAbiTarget) < 0)
			targets.push(session.nativeAbiTarget);
		for (classDecl in classes)
			byName.set(classDecl.name, classDecl);
		for (target in targets) {
			var layouts:Map<String, TypedNativeLayout> = [];
			for (classDecl in classes)
				if (classDecl.isNativeValue)
					computeNativeLayout(classDecl.name, target, byName, layouts, []);
			layoutsByTarget.set(target, layouts);
		}
		return [
			for (classDecl in classes) {
				var nativeLayouts = classDecl.isNativeValue ? [for (target in targets) layoutsByTarget.get(target).get(classDecl.name)] : [];
				if (classDecl.isNativeValue) session.nativeLayoutsByName.set(classDecl.name, layoutsByTarget.get(session.nativeAbiTarget).get(classDecl.name));
				{
					name: classDecl.name,
					isValue: classDecl.isValue,
					isNativeValue: classDecl.isNativeValue,
					isNativeUnion: classDecl.isNativeUnion,
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

	function computeNativeLayout(name:String, target:String, classes:Map<String, TypedClass>, layouts:Map<String, TypedNativeLayout>,
			visiting:Map<String, Bool>):TypedNativeLayout {
		var cached = layouts.get(name);
		if (cached != null)
			return cached;
		var key = target + ":" + name, declaration = classes.get(name);
		if (declaration == null || !declaration.isNativeValue)
			throw 'Missing native value record "$name"';
		if (visiting.exists(key))
			BodyTyper.fail("E1022", 'Native value record "$name" contains a by-value layout cycle', declaration.span);
		if (declaration.fields.length == 0)
			BodyTyper.fail("E1022", 'Native value record "$name" must declare at least one field', declaration.span);
		visiting.set(key, true);
		var nativeDeclarations:Map<String, HxiDeclaration> = [];
		for (field in declaration.fields)
			collectNestedNativeDeclarations(field.type, target, classes, layouts, visiting, nativeDeclarations, field.span);
		var layout:TypedNativeLayout = try NativeLayout.record(target, name, [
			for (field in declaration.fields)
				{
					name: field.name,
					type: field.type,
					span: field.span,
					arrayLength: field.nativeArrayLength
				}
		], nativeDeclarations, declaration.span,
			declaration.isNativeUnion) catch (error:Dynamic) {
			visiting.remove(key);
			BodyTyper.fail("E1022", 'Invalid native value record "$name": ${Std.string(error)}', declaration.span);
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
				var nested = computeNativeLayout(name, target, classes, layouts, visiting),
					nestedClass = classes.get(name);
				result.set(name, NativeLayout.nestedDeclaration(name, nested, nestedClass.span));
			case _:
		}
	}

	function erasureType(declaration:compiler.syntax.Ast.AstInterface, type:compiler.syntax.Ast.AstType, span:SourceSpan):CompilerType {
		var substitutions:Map<String, CompilerType> = [];
		for (parameter in declaration.typeParameters)
			substitutions.set(parameter, TDynamic);
		return session.declarations.resolve(type, span, substitutions);
	}

	static function hasMetadata(metadata:Array<compiler.syntax.Ast.AstMetadata>, name:String):Bool {
		for (entry in metadata)
			if (entry.name == name)
				return true;
		return false;
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
			if (NativeLayout.containsNativeLayoutType(argument.type))
				BodyTyper.fail("E1022", 'Native layout types cannot be passed by value in function "${owner}.${method.name}" yet', method.span);
		if (NativeLayout.containsNativeLayoutType(result))
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

	function prependInstanceInitializers(method:TypedFunction, className:String, fields:Array<TypedField>):TypedFunction {
		var statements = instanceInitializerStatements(fields, className);
		return {
			name: method.name,
			owner: method.owner,
			isStatic: method.isStatic,
			isConstructor: method.isConstructor,
			arguments: method.arguments,
			result: method.result,
			statements: statements.concat(method.statements),
			cells: method.cells,
			cellCaptures: method.cellCaptures,
			span: method.span
		};
	}

	static function instanceInitializerStatements(fields:Array<TypedField>, className:String):Array<TypedStatement> {
		var statements:Array<TypedStatement> = [];
		for (field in fields) {
			var initializer = field.initializer;
			if (initializer == null)
				throw 'Missing initializer for "$className.${field.name}"';
			statements.push(TFieldAssign(new TypedExpression(TLocal("this"), TInstance(NominalKind.Class, className, []), field.span), field.name,
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
		if (!session.interfaceDecls.exists(interfaceName))
			return;
		var interfaceDecl = session.interfaceDecls.get(interfaceName),
			interfaceSubstitutions = bodyTyper.nominalSubstitutions(interfaceInstance);
		for (baseType in interfaceDecl.bases) {
			var baseInstance = session.declarations.resolve(baseType, interfaceDecl.span, interfaceSubstitutions),
				base = BodyTyper.inheritanceName(baseType);
			if (!session.interfaceDecls.exists(base))
				BodyTyper.fail("E1007", 'Unknown interface "$base"', span);
			validateInterfaceImplementation(classDecl, baseInstance, classSubstitutions, span);
		}
		for (method in interfaceDecl.methods) {
			var implementation = bodyTyper.findMethod(classDecl.name, method.name);
			if (implementation == null || implementation.isStatic)
				BodyTyper.fail("E1007", 'Class "${classDecl.name}" does not implement "$interfaceName.${method.name}"', span);
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
}
