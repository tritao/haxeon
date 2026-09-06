package compiler.semantic;

import compiler.modules.ModuleState;
import compiler.types.FieldInference;
import compiler.semantic.SemanticSignature;
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
			var signature = interfaceDecl.name
				+ '<${SemanticSignature.parsedParameters(interfaceDecl.typeParameters, interfaceDecl.typeConstraints, ast.aliases)}>'
				+ " extends "
				+ [for (base in interfaceDecl.bases) ModuleCanonicalizer.astTypeName(base)].join(",") + " {" + [
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
					+
					(alias.typeParameters.length == 0 ? "" : '<${SemanticSignature.parsedParameters(alias.typeParameters, alias.typeConstraints, ast.aliases)}>')
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
		var abstracts:Map<String, String> = [];
		for (abstractDecl in ast.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, abstractDecl.name),
				signature = abstractName
					+
					(abstractDecl.typeParameters.length == 0 ? "" : '<${SemanticSignature.parsedParameters(abstractDecl.typeParameters, abstractDecl.typeConstraints, ast.aliases)}>')
					+ "("
					+ SemanticSignature.parsed(abstractDecl.underlying, ast.aliases)
					+ ")"
					+ " from "
					+ [
						for (type in abstractDecl.fromTypes)
							SemanticSignature.parsed(type, ast.aliases)
					].join(",") + " to " + [for (type in abstractDecl.toTypes) SemanticSignature.parsed(type, ast.aliases)].join(",");
			abstracts.set(abstractName, signature);
			if (state.abstractFingerprints.get(abstractName) != signature)
				structuralChanged.set('abstract:$abstractName', true);
		}
		for (old in state.abstractFingerprints.keys())
			if (!abstracts.exists(old))
				structuralChanged.set('abstract:$old', true);
		state.abstractFingerprints = abstracts;
		var ownerConstraints:Map<String, String> = [];
		for (classDecl in ast.classes) {
			var name = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				signature = SemanticSignature.parsedParameters(classDecl.typeParameters, classDecl.typeConstraints, ast.aliases),
				isValue = false;
			for (metadata in classDecl.metadata)
				if (metadata.name == "value")
					isValue = true;
			signature += isValue ? ":value" : ":object";
			ownerConstraints.set(name, signature);
			if (state.ownerConstraintFingerprints.get(name) != signature)
				structuralChanged.set('constraint:$name', true);
		}
		for (interfaceDecl in ast.interfaces) {
			var name = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, interfaceDecl.name),
				signature = SemanticSignature.parsedParameters(interfaceDecl.typeParameters, interfaceDecl.typeConstraints, ast.aliases);
			ownerConstraints.set(name, signature);
			if (state.ownerConstraintFingerprints.get(name) != signature)
				structuralChanged.set('constraint:$name', true);
		}
		for (old in state.ownerConstraintFingerprints.keys())
			if (!ownerConstraints.exists(old))
				structuralChanged.set('constraint:$old', true);
		state.ownerConstraintFingerprints = ownerConstraints;
		var staticInitializers:Map<String, String> = [],
			instanceInitializers:Map<String, String> = [];
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name);
			for (field in classDecl.fields) {
				if (field.initializer == null)
					continue;
				var fieldName = className + "." + field.name,
					initializer = sourceFingerprint(state, field.span);
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
				body = sourceFingerprint(state, fn.span);
			signatures.set(fn.name, signature);
			bodies.set(fn.name, body);
			if (state.signatureFingerprints.get(fn.name) != signature)
				signatureChanged.set(canonical, true);
			else if (state.bodyFingerprints.get(fn.name) != body)
				bodyChanged.set(canonical, true);
		}
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				base = classDecl.base,
				baseName:Null<String> = null;
			if (base != null)
				baseName = SemanticSignature.parsed(base, ast.aliases);
			var classFields = [
				for (field in classDecl.fields)
					{name: field.name, type: SemanticSignature.parsed(FieldInference.parsedType(field), ast.aliases)}
			], classMethods = [
				for (method in classDecl.methods)
					{name: method.name, signature: SemanticSignature.parsedFunction(method, ast.aliases)}
				];
			var isValue = false;
			for (metadata in classDecl.metadata)
				if (metadata.name == "value")
					isValue = true;
			var typeResult = types.declareClass(className, baseName, classFields, classMethods, isValue);
			if (compiledOnce && typeResult.compatibility != Compatible)
				structuralChanged.set(className, true);
			for (method in classDecl.methods) {
				var localName = className + "." + method.name,
					canonical = localName,
					signature = SemanticSignature.parsedFunction(method, ast.aliases),
					body = sourceFingerprint(state, method.span);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(canonical, true);
				else if (state.bodyFingerprints.get(localName) != body)
					bodyChanged.set(canonical, true);
			}
		}
		for (abstractDecl in ast.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, abstractDecl.name);
			for (method in abstractDecl.methods) {
				var localName = abstractName + "." + method.name,
					signature = SemanticSignature.parsedFunction(method, ast.aliases),
					body = sourceFingerprint(state, method.span);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(localName, true);
				else if (state.bodyFingerprints.get(localName) != body)
					bodyChanged.set(localName, true);
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

	/** Include the source line because it is part of emitted debugger metadata. */
	static function sourceFingerprint(state:compiler.modules.ModuleState, span:compiler.Source.SourceSpan):String
		return state.source.path
			+ ":"
			+ Std.string(state.source.lineAt(span.start))
			+ ":"
			+ state.source.text.substring(span.start, span.end);
}
