package compiler.semantic;

import compiler.modules.ModuleState;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstVisibility;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;

/** Candidate fingerprint state and the invalidation classes derived from it. */
typedef ModuleChangeAnalysis = {
	final bodyChanged:Map<String, Bool>;
	final signatureChanged:Map<String, Bool>;
	final structuralChanged:Map<String, Bool>;
	final signatureFingerprints:Map<String, String>;
	final bodyFingerprints:Map<String, BodyFingerprint>;
	final interfaceFingerprints:Map<String, String>;
	final aliasFingerprints:Map<String, String>;
	final enumFingerprints:Map<String, String>;
	final abstractFingerprints:Map<String, String>;
	final ownerConstraintFingerprints:Map<String, String>;
	final wireFieldFingerprints:Map<String, String>;
	final staticFieldFingerprints:Map<String, String>;
	final instanceInitializerFingerprints:Map<String, String>;
}

/** Classifies source changes without publishing candidate fingerprints to a module. */
class ModuleChangeAnalyzer {
	public static function analyze(state:ModuleState, entry:String, typeAliases:AliasTable, types:TypeRegistry,
			compiledOnce:Bool):ModuleChangeAnalysis {
		var ast = state.parsedAst(),
			bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [];
		var signatures:Map<String, String> = [],
			bodies:Map<String, BodyFingerprint> = [];
		var wireFields:Map<String, String> = [];
		var interfaces:Map<String, String> = [];
		for (interfaceDecl in ast.interfaces) {
			var signature = interfaceDecl.visibility.modifier() + ":" + interfaceDecl.name
				+ '<${SemanticSignature.parsedParameters(interfaceDecl.typeParameters, interfaceDecl.typeConstraints, ast.aliases)}>'
				+ " extends "
				+ [for (base in interfaceDecl.bases) ModuleCanonicalizer.astTypeName(base)].join(",") + " {" + [
					for (field in interfaceDecl.fields)
						(field.visibility == AstVisibility.Unwritten ? "" : field.visibility.modifier() + " ")
						+ (field.isStatic ? "static " : "")
						+ (field.isFinal ? "final " : "var ") + field.name + "(" + field.readAccess + ","
						+ field.writeAccess + "):" + (field.type == null ? "_" : SemanticSignature.parsed(field.type,
						ast.aliases))
				].concat([
					for (method in interfaceDecl.methods)
						method.name + ":" + SemanticSignature.parsedFunction(method, ast.aliases)
				]).join(";") + "}";
			interfaces.set(interfaceDecl.name, signature);
			if (state.interfaceFingerprints.get(interfaceDecl.name) != signature)
				structuralChanged.set('interface:${interfaceDecl.name}', true);
		}
		for (old in state.interfaceFingerprints.keys())
			if (!interfaces.exists(old))
				structuralChanged.set('interface:$old', true);
		var aliases:Map<String, String> = [];
		for (alias in ast.aliases) {
			var aliasName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, alias.name),
				signature = alias.visibility.modifier() + ":" + aliasName
					+ (alias.typeParameters.length == 0 ? ""
					: '<${SemanticSignature.parsedParameters(alias.typeParameters, alias.typeConstraints, ast.aliases)}>')
					+ "="
					+ SemanticSignature.parsed(alias.type, ast.aliases);
			aliases.set(aliasName, signature);
			if (state.aliasFingerprints.get(aliasName) != signature)
				structuralChanged.set('alias:$aliasName', true);
		}
		for (old in state.aliasFingerprints.keys())
			if (!aliases.exists(old))
				structuralChanged.set('alias:$old', true);
		var enums:Map<String, String> = [];
		for (enumDecl in ast.enums) {
			var enumName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, enumDecl.name),
				signature = enumDecl.visibility.modifier() + ":" + enumName + "[" + fieldMetadataFingerprint(state,
					enumDecl.metadata) + "]:" + (enumDecl.conformances == null
					? "" : [for (type in enumDecl.conformances) SemanticSignature.parsed(type, ast.aliases)].join(","))
					+ "{" + [
						for (caseDecl in enumDecl.cases)
							caseDecl.name
							+ "["
							+ fieldMetadataFingerprint(state, caseDecl.metadata)
							+ "]("
							+ [
								for (param in caseDecl.params)
									(param.optional ? "?" : "") + SemanticSignature.parsed(param.type, ast.aliases)
							].join(",") + ")"
					].join(";") + "}";
			if (enumDecl.methods != null) for (method in enumDecl.methods)
				signature += ";method:" + method.visibility.modifier() + (method.isStatic ? ":static:" : ":")
				+ method.name
				+ ":" + SemanticSignature.parsedFunction(method, ast.aliases)
				+ ":" + sourceFingerprint(state, method.span);
			enums.set(enumName, signature);
			if (state.enumFingerprints.get(enumName) != signature)
				structuralChanged.set('enum:$enumName', true);
		}
		for (old in state.enumFingerprints.keys())
			if (!enums.exists(old))
				structuralChanged.set('enum:$old', true);
		var abstracts:Map<String, String> = [];
		for (abstractDecl in ast.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, abstractDecl.name),
				signature = abstractDecl.visibility.modifier() + ":" + abstractName
					+ (abstractDecl.typeParameters.length == 0 ? ""
					: '<${SemanticSignature.parsedParameters(abstractDecl.typeParameters, abstractDecl.typeConstraints, ast.aliases)}>')
					+ "("
					+ SemanticSignature.parsed(abstractDecl.underlying, ast.aliases)
					+ ")"
					+ " from "
					+ [
						for (type in abstractDecl.fromTypes)
							SemanticSignature.parsed(type, ast.aliases)
					].join(",") + " to "
					+ [for (type in abstractDecl.toTypes) SemanticSignature.parsed(type, ast.aliases)].join(",");
			// A property is read and written through its accessors, so its declaration is part of how the abstract types.
			signature += ":properties:"
				+ [
					for (field in abstractDecl.fields)
						(field.isStatic ? "static " : "") + field.name + "(" + field.readAccess + ","
						+ field.writeAccess + "):"
						+ (field.type == null ? "" : SemanticSignature.parsed(field.type, ast.aliases))
				].join(";");
			// Operator and conversion metadata changes the abstract's typing behavior, even if method signatures do not change.
			signature += ":method-metadata:"
				+ [for (method in abstractDecl.methods) if (method.isStatic && method.metadata != null)
				method.name + "=" + fieldMetadataFingerprint(state, method.metadata)].join(";");
			// An enum abstract's values, conformances and metadata (`@:annotation`) are part of how it types. Its readers inline
			// the values at their declarations and its conformance members are located at the abstract, so their lines count too,
			// as a static field initializer's do.
			if (abstractDecl.values != null)
				signature += ":enum@" + Std.string(state.source.lineAt(abstractDecl.span.start)) + "["
					+ fieldMetadataFingerprint(state, abstractDecl.metadata) + "]{"
					+ [
						for (value in abstractDecl.values)
							fieldMetadataFingerprint(state, value.metadata) + value.name + "="
							+ sourceFingerprint(state, value.span)
					].join(";") + "} implements " + (abstractDecl.conformances == null
					? "" : [for (type in abstractDecl.conformances) SemanticSignature.parsed(type,
					ast.aliases)].join(","));
			abstracts.set(abstractName, signature);
			if (state.abstractFingerprints.get(abstractName) != signature)
				structuralChanged.set('abstract:$abstractName', true);
		}
		for (old in state.abstractFingerprints.keys())
			if (!abstracts.exists(old))
				structuralChanged.set('abstract:$old', true);
		var ownerConstraints:Map<String, String> = [];
		for (classDecl in ast.classes) {
			var name = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				signature = SemanticSignature.parsedParameters(classDecl.typeParameters, classDecl.typeConstraints,
					ast.aliases),
				isValue = classDecl.isStruct == true,
				isNativeValue = false;
			for (metadata in classDecl.metadata)
				if (metadata.name == "value")
					isValue = true;
				else if (metadata.name == "repr" && metadata.arguments.length == 1)
					switch metadata.arguments[0] {
						case compiler.syntax.Ast.AstExpression.StringLiteral("C", _):
							isNativeValue = true;
						case _:
					}
			signature += classDecl.isStruct == true ? ":struct" : isNativeValue ? ":native-value" : isValue
				? ":value" : ":object";
			signature += ":metadata:" + fieldMetadataFingerprint(state, classDecl.metadata);
			// Where the class may be named (`internal`) is part of its declaration, as its kind is.
			signature += ":visibility:" + classDecl.visibility.modifier();
			ownerConstraints.set(name, signature);
			if (state.ownerConstraintFingerprints.get(name) != signature)
				structuralChanged.set('constraint:$name', true);
		}
		for (interfaceDecl in ast.interfaces) {
			var name = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, interfaceDecl.name),
				signature = SemanticSignature.parsedParameters(interfaceDecl.typeParameters,
					interfaceDecl.typeConstraints, ast.aliases);
			ownerConstraints.set(name, signature);
			if (state.ownerConstraintFingerprints.get(name) != signature)
				structuralChanged.set('constraint:$name', true);
		}
		for (old in state.ownerConstraintFingerprints.keys())
			if (!ownerConstraints.exists(old))
				structuralChanged.set('constraint:$old', true);
		var staticFields:Map<String, String> = [],
			instanceInitializers:Map<String, String> = [];
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name);
			// A static field's declaration is its readers' only source for its type, with or without an initializer: an edit to it is
			// structural for the field. An instance field's type is part of its class's layout (`declareClass` below).
			for (field in classDecl.fields) {
				if (field.initializer == null && !field.isStatic)
					continue;
				var fieldName = className + "." + field.name,
					initializer = sourceFingerprint(state, field.span);
				// An unannotated field's type is its initializer's: an edit to it is an edit to the field's signature.
				if (field.type == null
					&& (field.isStatic ? state.staticFieldFingerprints : state.instanceInitializerFingerprints)
					.get(fieldName) != initializer)
					signatureChanged.set(fieldName, true);
				if (field.isStatic) {
					staticFields.set(fieldName, initializer);
					if (!state.staticFieldFingerprints.exists(fieldName)
						|| state.staticFieldFingerprints.get(fieldName) != initializer) {
						structuralChanged.set('static:$fieldName', true);
						// An unannotated accessor takes the property's type (`AccessorSignatures`), so its signature changes with
						// the property's declaration; a read or write of the property calls it (`ClassProperties`).
						if (field.readAccess == GetAccess)
							signatureChanged.set(className + ".get_" + field.name, true);
						if (field.writeAccess == SetAccess)
							signatureChanged.set(className + ".set_" + field.name, true);
					}
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
		for (old in state.staticFieldFingerprints.keys())
			if (!staticFields.exists(old))
				structuralChanged.set('static:$old', true);
		for (old in state.instanceInitializerFingerprints.keys())
			if (!instanceInitializers.exists(old)) {
				var fieldName:String = old,
					className = compiler.core.QualifiedName.parentOrEmpty(fieldName),
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
		for (fn in ast.functions) {
			var canonical = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			var signature = SemanticSignature.parsedFunction(fn, ast.aliases)
				+ inferredFrom(state, fn),
				body = bodyFingerprint(state, fn.span, fn.typeParameters != null && fn.typeParameters.length > 0);
			signatures.set(fn.name, signature);
			bodies.set(fn.name, body);
			if (state.signatureFingerprints.get(fn.name) != signature)
				signatureChanged.set(canonical, true);
			else if (!body.equals(state.bodyFingerprints.get(fn.name)))
				bodyChanged.set(canonical, true);
		}
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				base = classDecl.base,
				baseName:Null<String> = null;
			if (base != null)
				baseName = SemanticSignature.parsed(base, ast.aliases);
			var classFields:Array<compiler.types.TypeRegistry.DeclaredField> = [for (field in classDecl.fields)
				{
					name: field.name,
					type: SemanticSignature.parsed(field.type ?? compiler.syntax.Ast.AstType.InferredType,
						ast.aliases)
				}],
				classMethods:Array<compiler.types.TypeRegistry.DeclaredMethod> = [for (method in classDecl.methods)
					{
						name: method.name, signature: SemanticSignature.parsedFunction(method, ast.aliases)
					}];
			var isValue = classDecl.isStruct == true, isNativeValue = false;
			for (metadata in classDecl.metadata)
				if (metadata.name == "value")
					isValue = true;
				else if (metadata.name == "repr" && metadata.arguments.length == 1)
					switch metadata.arguments[0] {
						case compiler.syntax.Ast.AstExpression.StringLiteral("C", _):
							isNativeValue = true;
						case _:
					}
			var wireFieldFingerprint = [
				for (field in classDecl.fields)
					field.name + "=" + field.visibility.modifier() + ":"
					+ fieldMetadataFingerprint(state, field.metadata)
			].join(";");
			wireFieldFingerprint += ":field-defaults:" + [
				for (field in classDecl.fields)
					if (!field.isStatic) field.name + "="
					+ (field.initializer == null ? "-" : sourceFingerprint(state, field.span))
			].join(";");
			var sourceKind = classDecl.isStruct == true ? "struct" : isNativeValue ? "native-value" : "class",
				declaredInterfaces = [
					for (interfaceType in classDecl.interfaces)
						SemanticSignature.parsed(interfaceType, ast.aliases)
				];
			declaredInterfaces.sort(Reflect.compare);
			wireFieldFingerprint += ":source-kind:" + sourceKind + ":interfaces:" + declaredInterfaces.join(";");
			wireFields.set(className, wireFieldFingerprint);
			if (state.wireFieldFingerprints.get(className) != wireFieldFingerprint)
				structuralChanged.set(className, true);
			var typeResult = types.declareClass(className, baseName, classFields, classMethods,
				isValue && !isNativeValue);
			// A method whose signature alone changed is a signature change (below), which names nothing new: the class's shape, which
			// the methods its subclasses discover (`@:discoverMethods`) are taken from, is the same.
			if (compiledOnce && typeResult.compatibility != Compatible
				&& typeResult.compatibility != MethodSignatureChanged)
				structuralChanged.set(className, true);
			for (method in classDecl.methods) {
				var localName = className + "." + method.name,
					canonical = localName,
					signature = SemanticSignature.parsedFunction(method, ast.aliases)
						+ inferredFrom(state, method),
					body = bodyFingerprint(state,
						method.span, classDecl.typeParameters.length > 0 || method.typeParameters != null
						&& method.typeParameters.length > 0);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(canonical, true);
				else if (!body.equals(state.bodyFingerprints.get(localName)))
					bodyChanged.set(canonical, true);
			}
		}
		for (abstractDecl in ast.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, abstractDecl.name);
			for (method in abstractDecl.methods) {
				var localName = abstractName + "." + method.name,
					signature = SemanticSignature.parsedFunction(method, ast.aliases)
						+ inferredFrom(state, method),
					body = bodyFingerprint(state,
						method.span, abstractDecl.typeParameters.length > 0 || method.typeParameters != null
						&& method.typeParameters.length > 0);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(localName, true);
				else if (!body.equals(state.bodyFingerprints.get(localName)))
					bodyChanged.set(localName, true);
			}
		}
		for (old in state.signatureFingerprints.keys())
			if (!signatures.exists(old)) {
				var canonical = ModuleCanonicalizer.canonicalName(state.name, entry, old);
				signatureChanged.set(canonical, true);
			}
		for (old in state.wireFieldFingerprints.keys())
			if (!wireFields.exists(old))
				structuralChanged.set(old, true);
		return {
			bodyChanged: bodyChanged,
			signatureChanged: signatureChanged,
			structuralChanged: structuralChanged,
			signatureFingerprints: signatures,
			bodyFingerprints: bodies,
			interfaceFingerprints: interfaces,
			aliasFingerprints: aliases,
			enumFingerprints: enums,
			abstractFingerprints: abstracts,
			ownerConstraintFingerprints: ownerConstraints,
			wireFieldFingerprints: wireFields,
			staticFieldFingerprints: staticFields,
			instanceInitializerFingerprints: instanceInitializers
		};
	}

	/** Makes `analysis` the module's fingerprints, which the next analysis compares against. */
	public static function publish(state:ModuleState, analysis:ModuleChangeAnalysis):Void {
		state.signatureFingerprints = analysis.signatureFingerprints;
		state.bodyFingerprints = analysis.bodyFingerprints;
		state.interfaceFingerprints = analysis.interfaceFingerprints;
		state.aliasFingerprints = analysis.aliasFingerprints;
		state.enumFingerprints = analysis.enumFingerprints;
		state.abstractFingerprints = analysis.abstractFingerprints;
		state.ownerConstraintFingerprints = analysis.ownerConstraintFingerprints;
		state.wireFieldFingerprints = analysis.wireFieldFingerprints;
		state.staticFieldFingerprints = analysis.staticFieldFingerprints;
		state.instanceInitializerFingerprints = analysis.instanceInitializerFingerprints;
	}

	/**
	 * What an unannotated part of a function's signature is inferred from, as source text; empty for a fully annotated function.
	 * Its result and its unannotated arguments come from its own body (and an argument's default value), so the function's text is
	 * part of its signature: before typing, nothing tells whether an edit to the body changed the inferred type, and the coarse
	 * rule (`LAZY_DECLARATION_TYPING.md`, "Invalidation") counts every such edit as a signature change. Only the text counts, not
	 * its line, which is debug metadata of the body alone.
	 */
	static function inferredFrom(state:compiler.modules.ModuleState, fn:compiler.syntax.Ast.AstFunction):String {
		if (!compiler.syntax.AstFunctions.leavesSignatureToInference(fn))
			return "";
		return " inferred-from:" + state.source.slice(fn.span.start, fn.span.end);
	}

	static function fieldMetadataFingerprint(state:compiler.modules.ModuleState,
			metadata:Array<compiler.syntax.Ast.AstMetadata>):String
		return [for (entry in metadata) state.source.slice(entry.span.start, entry.span.end)].join("|");

	/**
	 * Include the source line because it is part of emitted debugger metadata. A generic function also includes its offset:
	 * its specializations are kept from one build to the next while the function is unchanged, and they carry offsets in
	 * their debug mappings and in the names of their lambdas, so a function that only moved along its line must not keep them.
	 */
	/** `sourceFingerprint` of a function's body, compared without its text being copied. */
	static function bodyFingerprint(state:compiler.modules.ModuleState, span:compiler.core.Source.SourceSpan,
			generic:Bool = false):BodyFingerprint
		return new BodyFingerprint(state.source, span.start, span.end, generic ? span.start : -1);

	static function sourceFingerprint(state:compiler.modules.ModuleState, span:compiler.core.Source.SourceSpan,
			generic:Bool = false):String
		return state.source.path + ":" + Std.string(state.source.lineAt(span.start))
			+ (generic ? "@" + Std.string(span.start) : "") + ":"
			+ state.source.slice(span.start, span.end);
}
