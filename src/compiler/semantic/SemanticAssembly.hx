package compiler.semantic;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstFunction;
import compiler.compilation.CompilationContext;
import compiler.modules.ModuleState;
import compiler.service.CancellationToken;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;

typedef SemanticAssemblyResult = {
	final canonicalProgram:AstProgram;
	final functions:Array<AstFunction>;
	final owners:Map<String, String>;
	final generatedByModule:Map<String, Map<String, Bool>>;
	final selected:Map<String, Bool>;
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
			for (declaration in program.enumAbstracts)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
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
		var aliasUniverse = [for (sourceName => declarationName in sourceTypeAliases) sourceName + "=" + declarationName];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames)
				aliasUniverse.push(typeName + "#" + caseName);
		aliasUniverse.sort(Reflect.compare);
		var aliasKey = aliasUniverse.join(";");
		for (name in names) {
			if (token != null)
				token.check();
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
				for (callee in state.canonicalCalls.get(canonical.name)) {
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
				var classMethods:Array<AstFunction> = [];
				for (parsedMethod in classDecl.methods) {
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
					for (callee in calls.keys()) {
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
				var parsedBase = classDecl.base,
					canonicalBase:Null<compiler.syntax.Ast.AstType> = null;
				if (parsedBase != null)
					canonicalBase = ModuleCanonicalizer.canonicalType(parsedBase, classAliases, classDecl.typeParameters);
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
					fields: [
						for (field in classDecl.fields)
							{
								name: field.name,
								type: ModuleCanonicalizer.canonicalType(FieldInference.parsedType(field), classAliases, classDecl.typeParameters),
								initializer: ModuleCanonicalizer.canonicalOptionalExpression(field.initializer, name, entryModule, locals, aliases),
								readAccess: field.readAccess,
								writeAccess: field.writeAccess,
								isStatic: field.isStatic,
								isFinal: field.isFinal,
								span: field.span
							}
					],
					methods: classMethods,
					span: classDecl.span
				});
				owners.set(className + ".new", name);
			}
		}

		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		var invalid:Map<String, Bool> = [], allModulesChanged = true;
		// A new source revision owns a fresh position index. Retype every function
		// in that module so unchanged bodies cannot leave gaps or stale spans in it.
		for (moduleName in names) {
			var state = modules.get(moduleName);
			if (state.lastGoodRevision == state.revision)
				allModulesChanged = false;
			else
				for (fn in functions)
					if (owners.get(fn.name) == moduleName)
						invalid.set(fn.name, true);
		}
		if (!allModulesChanged) {
			for (change in structuralChanged.keys()) {
				var changedDependency:String = change,
					separator = changedDependency.indexOf(":"),
					target = separator < 0 ? changedDependency : changedDependency.substring(separator + 1, changedDependency.length);
				for (moduleName in names) {
					var dependencyState = modules.get(moduleName);
					for (owner => dependencies in dependencyState.semanticDependencies)
						for (dependency in dependencies) {
							var functionOwner:String = owner;
							if (SemanticDependencyCollector.sameDependencyTarget(dependency.target, target)) {
								var matchedFunction = false;
								for (fn in functions)
									if (fn.name == functionOwner || StringTools.startsWith(fn.name, functionOwner + ".")) {
										invalid.set(fn.name, true);
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
			invalid.set(name, true);
		var work:Array<String> = [for (name in signatureChanged.keys()) name], workCursor = 0;
		for (name in bodyChanged.keys())
			if (genericOrigins.exists(name))
				work.push(name);
		while (workCursor < work.length) {
			if (token != null)
				token.check();
			var changed = work[workCursor++];
			if (!invalid.exists(changed))
				invalid.set(changed, true);
			if (reverseCalls.exists(changed)) {
				var callers = reverseCalls.get(changed);
				for (caller in callers)
					if (!invalid.exists(caller))
						work.push(caller);
			}
		}
		// Semantic indexes are replaced as module-sized snapshots. If one function
		// changes meaning, type every function owned by that module before swapping
		// the index so no bindings from the previous snapshot survive.
		var invalidModules:Map<String, Bool> = [];
		for (functionName in invalid.keys()) {
			var owner = owners.get(functionName);
			if (owner != null)
				invalidModules.set(owner, true);
		}
		for (fn in functions) {
			var owner = owners.get(fn.name);
			if (owner != null && invalidModules.exists(owner))
				invalid.set(fn.name, true);
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
			selected: selected,
			entryPoint: entryPoint
		};
	}
}
