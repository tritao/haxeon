package compiler.modules;

import compiler.types.FieldInference;
import compiler.types.SemanticSignature;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;

/** Candidate fingerprint state and the invalidation classes derived from it. */
typedef ModuleChangeAnalysis = {
	final bodyChanged:Map<String, Bool>;
	final signatureChanged:Map<String, Bool>;
	final structuralChanged:Map<String, Bool>;
	final signatureFingerprints:Map<String, String>;
	final bodyFingerprints:Map<String, String>;
	final interfaceFingerprints:Map<String, String>;
	final aliasFingerprints:Map<String, String>;
	final enumFingerprints:Map<String, String>;
	final staticInitializerFingerprints:Map<String, String>;
	final instanceInitializerFingerprints:Map<String, String>;
}

/** Classifies source changes without publishing candidate fingerprints to a module. */
class ModuleChangeAnalyzer {
	public static function analyze(state:ModuleState, entry:String, typeAliases:Map<String, String>, types:TypeRegistry,
			compiledOnce:Bool):ModuleChangeAnalysis {
		var ast = state.parsedAst(),
			bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [];
		var signatures:Map<String, String> = [],
			bodies:Map<String, String> = [];
		var interfaces:Map<String, String> = [];
		for (interfaceDecl in ast.interfaces) {
			var signature = interfaceDecl.name + " extends " + interfaceDecl.bases.join(",") + " {" + [
				for (method in interfaceDecl.methods)
					method.name + ":" + SemanticSignature.parsedFunction(method, ast.aliases)
			].join(";") + "}";
			interfaces.set(interfaceDecl.name, signature);
			if (state.interfaceFingerprints.get(interfaceDecl.name) != signature)
				structuralChanged.set('interface:${interfaceDecl.name}', true);
		}
		for (old in state.interfaceFingerprints.keys())
			if (!interfaces.exists(old))
				structuralChanged.set('interface:$old', true);
		state.interfaceFingerprints = interfaces;
		var aliases:Map<String, String> = [];
		for (alias in ast.aliases) {
			var aliasName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, alias.name),
				signature = aliasName
					+ (alias.typeParameters.length == 0 ? "" : '<${alias.typeParameters.join(",")}>')
					+ "="
					+ SemanticSignature.parsed(alias.type, ast.aliases);
			aliases.set(aliasName, signature);
			if (state.aliasFingerprints.get(aliasName) != signature)
				structuralChanged.set('alias:$aliasName', true);
		}
		for (old in state.aliasFingerprints.keys())
			if (!aliases.exists(old))
				structuralChanged.set('alias:$old', true);
		state.aliasFingerprints = aliases;
		var enums:Map<String, String> = [];
		for (enumDecl in ast.enums) {
			var enumName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, enumDecl.name),
				signature = enumName + "{" + [
					for (caseDecl in enumDecl.cases)
						caseDecl.name + "(" + [
							for (param in caseDecl.params)
								(param.optional ? "?" : "") + SemanticSignature.parsed(param.type, ast.aliases)
						].join(",") + ")"
				].join(";") + "}";
			enums.set(enumName, signature);
			if (state.enumFingerprints.get(enumName) != signature)
				structuralChanged.set('enum:$enumName', true);
		}
		for (old in state.enumFingerprints.keys())
			if (!enums.exists(old))
				structuralChanged.set('enum:$old', true);
		state.enumFingerprints = enums;
		var staticInitializers:Map<String, String> = [],
			instanceInitializers:Map<String, String> = [];
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name);
			for (field in classDecl.fields) {
				if (field.initializer == null)
					continue;
				var fieldName = className + "." + field.name,
					initializer = state.source.text.substring(field.span.start, field.span.end);
				if (field.isStatic) {
					staticInitializers.set(fieldName, initializer);
					if (!state.staticInitializerFingerprints.exists(fieldName)
						|| state.staticInitializerFingerprints.get(fieldName) != initializer)
						structuralChanged.set('static:$fieldName', true);
				} else {
					instanceInitializers.set(fieldName, initializer);
					if (!state.instanceInitializerFingerprints.exists(fieldName)
						|| state.instanceInitializerFingerprints.get(fieldName) != initializer) {
						bodyChanged.set(className + ".new", true);
						var hasConstructor = false;
						for (method in classDecl.methods)
							if (method.name == "new")
								hasConstructor = true;
						if (!hasConstructor && !state.instanceInitializerFingerprints.exists(fieldName)) {
							structuralChanged.set(className, true);
							signatureChanged.set(className + ".new", true);
						}
					}
				}
			}
		}
		for (old in state.staticInitializerFingerprints.keys())
			if (!staticInitializers.exists(old))
				structuralChanged.set('static:$old', true);
		state.staticInitializerFingerprints = staticInitializers;
		for (old in state.instanceInitializerFingerprints.keys())
			if (!instanceInitializers.exists(old)) {
				var fieldName:String = old,
					className = compiler.QualifiedName.parentOrEmpty(fieldName),
					hasConstructor = false;
				for (classDecl in ast.classes)
					if (ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name) == className)
						for (method in classDecl.methods)
							if (method.name == "new")
								hasConstructor = true;
				bodyChanged.set(className + ".new", true);
				if (!hasConstructor) {
					structuralChanged.set(className, true);
					signatureChanged.set(className + ".new", true);
				}
			}
		state.instanceInitializerFingerprints = instanceInitializers;
		for (fn in ast.functions) {
			var canonical = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			var signature = SemanticSignature.parsedFunction(fn, ast.aliases),
				body = state.source.text.substring(fn.span.start, fn.span.end);
			signatures.set(fn.name, signature);
			bodies.set(fn.name, body);
			if (state.signatureFingerprints.get(fn.name) != signature)
				signatureChanged.set(canonical, true);
			else if (state.bodyFingerprints.get(fn.name) != body)
				bodyChanged.set(canonical, true);
		}
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				baseName = ModuleCanonicalizer.resolveOptionalTypeName(classDecl.base, typeAliases);
			var classFields = [
				for (field in classDecl.fields)
					{name: field.name, type: SemanticSignature.parsed(FieldInference.parsedType(field), ast.aliases)}
			], classMethods = [
				for (method in classDecl.methods)
					{name: method.name, signature: SemanticSignature.parsedFunction(method, ast.aliases)}
				];
			var typeResult = types.declareClass(className, baseName, classFields, classMethods);
			if (compiledOnce && typeResult.compatibility != Compatible)
				structuralChanged.set(className, true);
			for (method in classDecl.methods) {
				var localName = className + "." + method.name,
					canonical = localName,
					signature = SemanticSignature.parsedFunction(method, ast.aliases),
					body = state.source.text.substring(method.span.start, method.span.end);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(canonical, true);
				else if (state.bodyFingerprints.get(localName) != body)
					bodyChanged.set(canonical, true);
			}
		}
		for (old in state.signatureFingerprints.keys())
			if (!signatures.exists(old)) {
				var canonical = ModuleCanonicalizer.canonicalName(state.name, entry, old);
				signatureChanged.set(canonical, true);
			}
		state.signatureFingerprints = signatures;
		state.bodyFingerprints = bodies;
		return {
			bodyChanged: bodyChanged,
			signatureChanged: signatureChanged,
			structuralChanged: structuralChanged,
			signatureFingerprints: signatures,
			bodyFingerprints: bodies,
			interfaceFingerprints: interfaces,
			aliasFingerprints: aliases,
			enumFingerprints: enums,
			staticInitializerFingerprints: staticInitializers,
			instanceInitializerFingerprints: instanceInitializers
		};
	}
}
