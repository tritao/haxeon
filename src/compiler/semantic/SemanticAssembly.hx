package compiler.semantic;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.compilation.CompilationContext;
import compiler.modules.ModuleState;
import compiler.service.CancellationToken;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;
import compiler.semantic.Invalidation.InvalidationReason;

typedef SemanticAssemblyResult = {
	final canonicalProgram:AstProgram;
	final functions:Array<AstFunction>;
	final owners:Map<String, String>;
	final generatedByModule:Map<String, Map<String, Bool>>;
	final invalidated:Map<String, Bool>;
	final selected:Map<String, Bool>;
	final invalidations:Array<InvalidatedArtifact>;
	final entryPoint:String;
}

/** Canonicalizes reachable declarations and selects functions invalidated by source changes. */
class SemanticAssembly {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			names:Array<String>, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):SemanticAssemblyResult {
		var modules = context.modules;
		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.syntax.Ast.AstTypeAlias> = [],
			enums:Array<compiler.syntax.Ast.AstEnum> = [],
			enumAbstracts:Array<compiler.syntax.Ast.AstEnumAbstract> = [],
			abstracts:Array<compiler.syntax.Ast.AstAbstract> = [],
			interfaces:Array<compiler.syntax.Ast.AstInterface> = [],
			classes:Array<compiler.syntax.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [],
			reverseCalls:Map<String, Array<String>> = [],
			genericOrigins:Map<String, Bool> = [];
		var sourceTypeAliases:Map<String, String> = [],
			enumCasesByType:Map<String, Array<String>> = [],
			enumConstructorCounts:Map<String, Int> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var moduleState = modules.get(moduleName),
				program = moduleState.parsedAst();
			for (declaration in program.aliases)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.enums) {
				var canonicalName = ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name);
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name), canonicalName);
				enumCasesByType.set(canonicalName, [for (enumCase in declaration.cases) enumCase.name]);
				for (enumCase in declaration.cases) {
					var count = enumConstructorCounts.exists(enumCase.name) ? enumConstructorCounts.get(enumCase.name) : 0;
					enumConstructorCounts.set(enumCase.name, count + 1);
				}
			}
			for (declaration in program.enumAbstracts) {
				var canonicalName = ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name);
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					canonicalName);
				enumCasesByType.set(canonicalName, [for (enumCase in declaration.values) enumCase.name]);
				for (enumCase in declaration.values) {
					var count = enumConstructorCounts.exists(enumCase.name) ? enumConstructorCounts.get(enumCase.name) : 0;
					enumConstructorCounts.set(enumCase.name, count + 1);
				}
			}
			for (declaration in program.abstracts)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.interfaces)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.classes)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
		}
		var aliasUniverse = [
			for (sourceName => declarationName in sourceTypeAliases)
				sourceName + "=" + declarationName
		];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames)
				aliasUniverse.push(typeName + "#" + caseName);
		aliasUniverse.sort(Reflect.compare);
		var aliasKey = aliasUniverse.join(";");
		var classDeclarations:Map<String, AstClass> = [];
		for (moduleName in names)
			if (modules.exists(moduleName)) {
				var parsed = modules.get(moduleName).parsedAst();
				for (classDecl in parsed.classes)
					classDeclarations.set(ModuleCanonicalizer.qualifiedTypeName(parsed.packageName, classDecl.name), classDecl);
			}

		var discoveryPrefixes:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var program = modules.get(moduleName).parsedAst();
			for (classDecl in program.classes) {
				var prefixes = declaredDiscoveryPrefixes(classDecl);
				if (prefixes != null)
					discoveryPrefixes.set(ModuleCanonicalizer.qualifiedTypeName(program.packageName, classDecl.name), prefixes);
			}
		}
		for (name in names) {
			if (token != null)
				token.check();
			if (!modules.exists(name))
				continue;
			var state = modules.get(name),
				ast = state.parsedAst(),
				locals:Map<String, Bool> = [],
				aliases = context.importAliases(ast.imports, ast.importAliases);
			for (sourceName => declarationName in sourceTypeAliases)
				aliases.set(sourceName, declarationName);
			var constructorTargets:Map<String, String> = [],
				ambiguousConstructors:Map<String, Bool> = [];
			for (importPath in ast.imports) {
				var importedType = sourceTypeAliases.get(importPath);
				if (importedType != null && enumCasesByType.exists(importedType))
					for (caseName in enumCasesByType.get(importedType))
						if (constructorTargets.exists(caseName))
							ambiguousConstructors.set(caseName, true);
						else
							constructorTargets.set(caseName, importedType + "." + caseName);
			}
			for (caseName => target in constructorTargets)
				if (!ambiguousConstructors.exists(caseName) && enumConstructorCounts.get(caseName) == 1 && !aliases.exists(caseName))
					aliases.set(caseName, target);
			for (importPath in ast.imports)
				if (modules.exists(importPath))
					for (sourceName => declarationName in sourceTypeAliases) {
						var qualifiedSourceName:String = sourceName;
						if (StringTools.startsWith(qualifiedSourceName, importPath + ".")) {
							var nestedStart = importPath.length + 1,
								nestedName = qualifiedSourceName.substring(nestedStart, qualifiedSourceName.length);
							if (nestedName.indexOf(".") < 0)
								aliases.set(nestedName, declarationName);
						}
					}
			var visiblePackage = ast.packageName;
			while (true) {
				var currentPackage:String;
				if (visiblePackage == null)
					break;
				else
					currentPackage = visiblePackage;
				var packagePrefix = currentPackage.length == 0 ? "" : currentPackage + ".";
				for (sourceName => declarationName in sourceTypeAliases) {
					var qualifiedSourceName:String = sourceName,
						qualifiedDeclarationName:String = declarationName;
					if (StringTools.startsWith(qualifiedSourceName, packagePrefix)
						&& StringTools.startsWith(qualifiedDeclarationName, packagePrefix)) {
						var relativeSourceName = qualifiedSourceName.substring(packagePrefix.length, qualifiedSourceName.length),
							simpleName = qualifiedDeclarationName.substring(packagePrefix.length, qualifiedDeclarationName.length);
						if (!aliases.exists(relativeSourceName))
							aliases.set(relativeSourceName, declarationName);
						if (simpleName.indexOf(".") < 0 && !aliases.exists(simpleName))
							aliases.set(simpleName, declarationName);
					}
				}
				var separator = -1,
					separatorCursor = currentPackage.length - 1;
				while (separatorCursor >= 0) {
					if (currentPackage.charCodeAt(separatorCursor) == 46) {
						separator = separatorCursor;
						break;
					}
					separatorCursor--;
				}
				visiblePackage = separator < 0 ? null : currentPackage.substring(0, separator);
			}
			ModuleCanonicalizer.addDeclaredTypeAliases(aliases, ast, ast.packageName);
			for (interfaceDecl in ast.interfaces)
				interfaces.push(ModuleCanonicalizer.canonicalInterface(interfaceDecl, aliases, ast.packageName));
			for (alias in ast.aliases)
				typeAliases.push(ModuleCanonicalizer.canonicalAlias(alias, aliases, ast.packageName));
			for (enumDecl in ast.enums)
				enums.push(ModuleCanonicalizer.canonicalEnum(enumDecl, aliases, ast.packageName));
			for (abstractDecl in ast.enumAbstracts)
				enumAbstracts.push(ModuleCanonicalizer.canonicalEnumAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals));
			for (abstractDecl in ast.abstracts) {
				var canonicalAbstract = ModuleCanonicalizer.canonicalAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals);
				abstracts.push(canonicalAbstract);
				for (method in canonicalAbstract.methods) {
					var qualified = canonicalAbstract.name + "." + method.name,
						canonicalMethod:AstFunction = {
							name: qualified,
							isStatic: method.isStatic,
							typeParameters: method.typeParameters,
							typeConstraints: method.typeConstraints,
							arguments: method.arguments,
							result: method.result,
							span: method.span,
							statements: method.statements
						};
					functions.push(canonicalMethod);
					owners.set(qualified, name);
					if (canonicalAbstract.typeParameters.length > 0 || (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(qualified, true);
					LambdaCollector.collect(method.statements, qualified, name, generatedByModule);
				}
			}
			for (fn in ast.functions)
				locals.set(fn.name, true);
			var canonicalFunctions:Array<AstFunction>;
			if (state.canonicalRevision == state.revision && state.canonicalEntry == entryModule && state.canonicalAliasKey == aliasKey)
				canonicalFunctions = state.canonicalFunctions;
			else {
				state = context.writableState(name, rollbackModules);
				canonicalFunctions = [
					for (fn in ast.functions)
						ModuleCanonicalizer.canonicalFunction(fn, name, entryModule, locals, null, aliases)
				];
				var canonicalCalls:Map<String, Array<String>> = [];
				for (canonical in canonicalFunctions) {
					var calls:Map<String, Bool> = [],
						localAliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, localAliases);
					canonicalCalls.set(canonical.name, [for (callee in calls.keys()) callee]);
				}
				state.canonicalFunctions = canonicalFunctions;
				state.canonicalRevision = state.revision;
				state.canonicalEntry = entryModule;
				state.canonicalAliasKey = aliasKey;
				state.canonicalCalls = canonicalCalls;
			}
			for (canonical in canonicalFunctions) {
				functions.push(canonical);
				programFunctions.push(canonical);
				owners.set(canonical.name, name);
				if (canonical.typeParameters != null && canonical.typeParameters.length > 0)
					genericOrigins.set(canonical.name, true);
				LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
				for (callee in dependencyCalls(state, rollbackModules, canonical.name, state.canonicalCalls.get(canonical.name))) {
					var callers:Array<String>;
					if (reverseCalls.exists(callee))
						callers = reverseCalls.get(callee);
					else {
						callers = [];
						reverseCalls.set(callee, callers);
					}
					callers.push(canonical.name);
				}
			}
			for (classDecl in ast.classes) {
				var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
					classAliases:Map<String, String> = [for (alias => target in aliases) alias => target];
				for (parameter in classDecl.typeParameters)
					classAliases.set(parameter, parameter);
				var parsedBase = classDecl.base,
					canonicalBase:Null<compiler.syntax.Ast.AstType> = null;
				if (parsedBase != null)
					canonicalBase = ModuleCanonicalizer.canonicalType(parsedBase, classAliases, classDecl.typeParameters);
				var parsedMethods = classDecl.methods;
				var baseName = nominalTypeName(canonicalBase);
				if (baseName != null && discoveryPrefixes.exists(baseName)) {
					var prefixes = discoveryPrefixes.get(baseName);
					discoveryPrefixes.set(className, prefixes);
					parsedMethods = discoveredMethods(classDecl, className, prefixes);
				}
				var classMethods:Array<AstFunction> = [];
				for (parsedMethod in parsedMethods) {
					var method = SignatureInference.inferFieldBoundArguments(parsedMethod, classDecl);
					var canonical = ModuleCanonicalizer.canonicalFunction(method, name, entryModule, locals, className + "." + method.name, classAliases);
					functions.push(canonical);
					classMethods.push({
						name: method.name,
						isStatic: method.isStatic,
						isExtern: method.isExtern,
						metadata: method.metadata,
						typeParameters: method.typeParameters,
						typeConstraints: canonical.typeConstraints,
						arguments: canonical.arguments,
						result: canonical.result,
						span: method.span,
						statements: canonical.statements
					});
					owners.set(canonical.name, name);
					if (classDecl.typeParameters.length > 0 || (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(canonical.name, true);
					var calls:Map<String, Bool> = [];
					var aliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, aliases);
					LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
					for (callee in dependencyCalls(state, rollbackModules, canonical.name, [for (name in calls.keys()) name])) {
						var callers:Array<String>;
						if (reverseCalls.exists(callee))
							callers = reverseCalls.get(callee);
						else {
							callers = [];
							reverseCalls.set(callee, callers);
						}
						callers.push(canonical.name);
					}
				}
				var canonicalFields:Array<compiler.syntax.Ast.AstField> = [];
				for (field in classDecl.fields) {
					var initializer = ModuleCanonicalizer.canonicalOptionalExpression(field.initializer, name, entryModule, locals, aliases);
					if (initializer != null)
						LambdaCollector.collectExpression(initializer, className + ".__init", name, generatedByModule);
					canonicalFields.push({
						name: field.name,
						type: ModuleCanonicalizer.canonicalType(FieldInference.resolvedType(field, className, classDeclarations, classAliases), classAliases,
							classDecl.typeParameters),
						initializer: initializer,
						readAccess: field.readAccess,
						writeAccess: field.writeAccess,
						isStatic: field.isStatic,
						isInline: field.isInline,
						isFinal: field.isFinal,
						span: field.span
					});
				}
				classes.push({
					name: className,
					isExtern: classDecl.isExtern,
					typeParameters: classDecl.typeParameters,
					typeConstraints: classDecl.typeConstraints,
					isPrivate: classDecl.isPrivate,
					metadata: classDecl.metadata,
					base: canonicalBase,
					interfaces: [
						for (interfaceType in classDecl.interfaces)
							ModuleCanonicalizer.canonicalType(interfaceType, classAliases, classDecl.typeParameters)
					],
					fields: canonicalFields,
					methods: classMethods,
					span: classDecl.span
				});
				owners.set(className + ".new", name);
			}
		}

		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		var invalid:Map<String, Bool> = [],
			invalidationReasons:Map<String, Array<InvalidationReason>> = [],
			initialBuild = true;
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var state = modules.get(moduleName);
			if (state.lastGoodRevision != 0)
				initialBuild = false;
		}
		if (initialBuild) {
			for (fn in functions)
				invalidate(invalid, invalidationReasons, fn.name, SourceRevision, owners.get(fn.name));
		} else {
			for (change in structuralChanged.keys()) {
				var changedDependency:String = change,
					separator = changedDependency.indexOf(":"),
					target = separator < 0 ? changedDependency : changedDependency.substring(separator + 1, changedDependency.length),
					targetId = context.resolveSemanticType(target);
				if (targetId == null)
					targetId = context.resolveSemanticSymbol(target);
				for (moduleName in names) {
					if (!modules.exists(moduleName))
						continue;
					var dependencyState = modules.get(moduleName);
					for (owner => dependencies in dependencyState.semanticDependencies)
						for (dependency in dependencies) {
							var functionOwner:String = owner;
							var matches = dependency.targetId != null
								&& targetId != null ? dependency.targetId == targetId : SemanticDependencyCollector.sameDependencyTarget(dependency.target,
									target);
							if (matches) {
								invalidate(invalid, invalidationReasons, functionOwner, StructuralDependency, target, targetId, Std.string(dependency.kind));
								var matchedFunction = false;
								for (fn in functions)
									if (fn.name == functionOwner || StringTools.startsWith(fn.name, functionOwner + ".")) {
										invalidate(invalid, invalidationReasons, fn.name, StructuralDependency, target, targetId, Std.string(dependency.kind));
										matchedFunction = true;
									}
								if (matchedFunction)
									break;
							}
						}
				}
			}
		}
		for (name in bodyChanged.keys())
			invalidate(invalid, invalidationReasons, name, BodyChanged, name);
		var reverseBodyDependencies:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			for (owner => dependencies in modules.get(moduleName).semanticDependencies)
				for (dependency in dependencies)
					if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body && dependency.targetId != null) {
						var dependents = reverseBodyDependencies.get(dependency.targetId);
						if (dependents == null) {
							dependents = [];
							reverseBodyDependencies.set(dependency.targetId, dependents);
						}
						dependents.push(owner);
					}
		}
		var work:Array<String> = [for (name in signatureChanged.keys()) name], workCursor = 0;
		for (name in bodyChanged.keys())
			if (genericOrigins.exists(name)) {
				work.push(name);
				invalidate(invalid, invalidationReasons, name, GenericOrigin, name);
			}
		while (workCursor < work.length) {
			if (token != null)
				token.check();
			var changed = work[workCursor++];
			if (signatureChanged.exists(changed))
				invalidate(invalid, invalidationReasons, changed, SignatureChanged, changed, context.resolveSemanticSymbol(changed));
			else if (!invalid.exists(changed))
				invalidate(invalid, invalidationReasons, changed, DependencySignature, changed);
			var changedId = context.resolveSemanticSymbol(changed);
			if (changedId != null && reverseBodyDependencies.exists(changedId))
				for (owner in reverseBodyDependencies.get(changedId))
					if (!invalid.exists(owner)) {
						work.push(owner);
						invalidate(invalid, invalidationReasons, owner, DependencySignature, changed, changedId,
							Std.string(compiler.modules.ModuleState.SemanticDependencyKind.Body));
					}
			if (reverseCalls.exists(changed)) {
				var callers = reverseCalls.get(changed);
				for (caller in callers)
					if (!invalid.exists(caller)) {
						work.push(caller);
						invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId, "provisional-call");
					}
			}
		}
		var invalidated:Map<String, Bool> = [];
		for (name in invalid.keys())
			invalidated.set(name, true);
		// Semantic indexes are replaced as module-sized snapshots. If one function
		// changes meaning, or its source revision changes, refresh every function in
		// that module without reporting the unchanged functions as invalidated.
		var invalidModules:Map<String, Bool> = [];
		for (functionName in invalid.keys()) {
			var owner = owners.get(functionName);
			if (owner != null)
				invalidModules.set(owner, true);
		}
		for (moduleName in names)
			if (modules.exists(moduleName) && modules.get(moduleName).lastGoodRevision != modules.get(moduleName).revision)
				invalidModules.set(moduleName, true);
		for (fn in functions) {
			var owner = owners.get(fn.name);
			if (owner != null && invalidModules.exists(owner) && !invalid.exists(fn.name))
				invalidate(invalid, invalidationReasons, fn.name, ModuleSemanticSnapshot, owner);
		}
		var selected:Map<String, Bool> = [];
		for (name in invalid.keys())
			selected.set(name, true);
		var entryPoint = context.executableEntryPoint(entryModule);
		var canonicalProgram:AstProgram = {
			packageName: null,
			imports: [],
			importAliases: [],
			aliases: typeAliases,
			enums: enums,
			enumAbstracts: enumAbstracts,
			abstracts: abstracts,
			interfaces: interfaces,
			classes: classes,
			functions: programFunctions
		};
		return {
			canonicalProgram: canonicalProgram,
			functions: functions,
			owners: owners,
			generatedByModule: generatedByModule,
			invalidated: invalidated,
			selected: selected,
			invalidations: orderedInvalidations(invalidationReasons),
			entryPoint: entryPoint
		};
	}

	static function invalidate(invalid:Map<String, Bool>, reasons:Map<String, Array<InvalidationReason>>, artifact:String, kind:InvalidationKind,
			cause:String, ?causeId:String, ?via:String):Void {
		invalid.set(artifact, true);
		var entries = reasons.get(artifact);
		if (entries == null) {
			entries = [];
			reasons.set(artifact, entries);
		}
		for (entry in entries)
			if (entry.kind == kind && entry.cause == cause && entry.causeId == causeId && entry.via == via)
				return;
		entries.push({
			kind: kind,
			cause: cause,
			causeId: causeId,
			via: via
		});
	}

	static function orderedInvalidations(reasons:Map<String, Array<InvalidationReason>>):Array<InvalidatedArtifact> {
		var names = [for (name in reasons.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {artifact: name, reasons: reasons.get(name)}];
	}

	/** Prefer the last successfully resolved call graph; syntax calls bootstrap new declarations. */
	static function dependencyCalls(state:ModuleState, rollbackModules:Map<String, ModuleState>, owner:String, fallback:Array<String>):Array<String> {
		var previous = rollbackModules.exists(state.name) ? rollbackModules.get(state.name) : state,
			dependencies = previous.semanticDependencies.get(owner),
			resolved:Array<String> = [];
		if (dependencies != null)
			for (dependency in dependencies)
				if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body && dependency.targetId != null)
					resolved.push(dependency.target);
		return resolved.length == 0 ? fallback : resolved;
	}

	static function declaredDiscoveryPrefixes(classDecl:AstClass):Null<Array<String>> {
		for (metadata in classDecl.metadata)
			if (metadata.name == "discoverMethods") {
				if (metadata.arguments.length == 0)
					throw new CompileError(new Diagnostic("E1024", "@:discoverMethods requires at least one prefix", metadata.span));
				var prefixes:Array<String> = [];
				for (argument in metadata.arguments)
					switch argument {
						case AstExpression.StringLiteral(value, _):
							prefixes.push(value);
						default:
							throw new CompileError(new Diagnostic("E1024", "@:discoverMethods prefixes must be string literals", metadata.span));
					}
				return prefixes;
			}
		return null;
	}

	static function discoveredMethods(classDecl:AstClass, className:String, prefixes:Array<String>):Array<AstFunction> {
		for (method in classDecl.methods)
			if (method.name == "registerTests")
				return classDecl.methods;
		var statements:Array<AstStatement> = [];
		for (method in classDecl.methods) {
			var discovered = false;
			for (prefix in prefixes)
				if (StringTools.startsWith(method.name, prefix))
					discovered = true;
			if (!discovered)
				continue;
			if (method.isStatic || method.arguments.length != 0)
				throw new CompileError(new Diagnostic("E1024", 'Discovered method "$className.${method.name}" must be a parameterless instance method',
					method.span));
			switch method.result {
				case AstType.VoidType, AstType.InferredType:
				default:
					throw new CompileError(new Diagnostic("E1024", 'Discovered method "$className.${method.name}" must return Void', method.span));
			}
			var receiver = AstExpression.Variable("this", method.span);
			statements.push(AstStatement.Expression(AstExpression.MethodCall(receiver, "addTest", [
				AstExpression.StringLiteral(className + "." + method.name, method.span),
				AstExpression.Member(AstExpression.Variable("this", method.span), method.name, method.span)
			], method.span), method.span));
		}
		var methods = classDecl.methods.copy();
		methods.push({
			name: "registerTests",
			isStatic: false,
			isExtern: false,
			metadata: [],
			typeParameters: [],
			typeConstraints: [],
			arguments: [],
			result: AstType.VoidType,
			statements: statements,
			span: classDecl.span
		});
		return methods;
	}

	static function nominalTypeName(type:Null<AstType>):Null<String>
		return switch type {
			case AstType.NamedType(name), AstType.AppliedType(name, _): name;
			default: null;
		};
}
