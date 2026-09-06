package compiler.semantic;

import compiler.Ast;
import compiler.Ast.AstFunction;
import compiler.CompilationContext;
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
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>, names:Array<String>, bodyChanged:Map<String, Bool>,
			signatureChanged:Map<String, Bool>, structuralChanged:Map<String, Bool>):SemanticAssemblyResult {
		var modules = context.modules;
		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.Ast.AstTypeAlias> = [],
			enums:Array<compiler.Ast.AstEnum> = [],
			enumAbstracts:Array<compiler.Ast.AstEnumAbstract> = [],
			abstracts:Array<compiler.Ast.AstAbstract> = [],
			interfaces:Array<compiler.Ast.AstInterface> = [],
			classes:Array<compiler.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [],
			reverseCalls:Map<String, Array<String>> = [];
		var sourceTypeAliases:Map<String, String> = [];
		for (moduleName in names) {
			var moduleState = modules.get(moduleName),
				program = moduleState.parsedAst();
			for (declaration in program.aliases)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.enums)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
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
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name),
				ast = state.parsedAst(),
				locals:Map<String, Bool> = [],
				aliases = context.importAliases(ast.imports, ast.importAliases);
			for (sourceName => declarationName in sourceTypeAliases)
				aliases.set(sourceName, declarationName);
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
			for (abstractDecl in ast.abstracts)
				abstracts.push(ModuleCanonicalizer.canonicalAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals));
			for (fn in ast.functions)
				locals.set(fn.name, true);
			var aliasNames = [for (aliasName in aliases.keys()) aliasName];
			aliasNames.sort(Reflect.compare);
			var aliasKey = [for (aliasName in aliasNames) aliasName + "=" + aliases.get(aliasName)].join(";");
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
						typeParameters: method.typeParameters,
						arguments: canonical.arguments,
						result: canonical.result,
						span: method.span,
						statements: canonical.statements
					});
					owners.set(canonical.name, name);
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
				classes.push({
					name: className,
					typeParameters: classDecl.typeParameters,
					isPrivate: classDecl.isPrivate,
					metadata: classDecl.metadata,
					base: classDecl.base == null ? null : ModuleCanonicalizer.canonicalType(classDecl.base, classAliases, classDecl.typeParameters),
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
		var invalid:Map<String, Bool> = [];
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
		for (name in bodyChanged.keys())
			invalid.set(name, true);
		var work:Array<String> = [for (name in signatureChanged.keys()) name], workCursor = 0;
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
