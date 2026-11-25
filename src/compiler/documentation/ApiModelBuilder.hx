package compiler.documentation;

import compiler.core.Source.SourceFile;
import compiler.core.Source.SourceSpan;
import compiler.documentation.ApiModel.ApiDeclaration;
import compiler.documentation.ApiModel.ApiMember;
import compiler.documentation.ApiModel.ApiModule;
import compiler.documentation.ApiModel.ApiSource;
import compiler.documentation.ApiModel.ApiType;
import compiler.documentation.ApiModel.ApiTypeParameter;
import compiler.documentation.Documentation.DocumentationComment;
import compiler.documentation.Documentation;
import compiler.documentation.Documentation.DocumentationTools;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.semantic.AbstractStatics;
import compiler.semantic.InterfaceFieldAccessors;
import compiler.semantic.ModuleFields;
import compiler.semantic.SemanticProgram;
import compiler.syntax.Ast;
import compiler.syntax.AstPredicates;
import compiler.syntax.Parser;
import compiler.types.Type.CompilerType;
import haxe.ds.ObjectMap;
import haxe.io.Path;

private typedef ApiOwner = {
	final name:String;
	final span:SourceSpan;
	final typeParameters:Array<String>;
	final typeConstraints:Null<Array<AstTypeConstraint>>;
}

/** Projects the semantic program and its source-bearing declarations into the public API. */
class ApiModelBuilder {
	final semantic:SemanticProgram;
	final modules:Map<String, String> = [];
	final comments = new ObjectMap<SourceFile, Array<DocumentationComment>>();
	final roots:Array<String>;

	/** The packages sources belong to, with their roots as absolute directories, the innermost first. */
	final packages:Array<{name:String, root:String}>;

	/**
	 * The model of `semantic`, whose `described` modules are the API. A source in one of `packages` is given relative to that
	 * package's root; any other (the standard library's) relative to the source root of `roots` that holds it.
	 */
	public static function build(semantic:SemanticProgram, modules:Map<String, ModuleState>, roots:Array<String>,
			described:Array<String>, ?packages:Array<{name:String, root:String}>):ApiModel
		return new ApiModelBuilder(semantic, modules, roots, packages ?? []).model(described);

	function new(semantic:SemanticProgram, states:Map<String, ModuleState>, roots:Array<String>,
			packages:Array<{name:String, root:String}>) {
		this.semantic = semantic;
		for (state in states)
			modules.set(state.source.path, state.name);
		this.roots = [for (root in roots) Path.addTrailingSlash(absolute(root))];
		this.roots.sort((left, right) -> right.length - left.length);
		// A package inside another's directory (a checkout's packages/ under its root) owns what it holds.
		this.packages = [for (entry in packages) {
			name: entry.name, root: Path.addTrailingSlash(absolute(entry.root))
		}];
		this.packages.sort((left, right) -> right.root.length - left.root.length);
	}

	function model(described:Array<String>):ApiModel {
		var types:Array<ApiDeclaration> = [],
			program = semantic.program,
			modules = new Map<String, ApiModule>();
		function moduleOf(span:SourceSpan):Array<ApiMember> {
			var path = moduleName(span), module = modules.get(path);
			if (module == null) {
				var location = locate(span.file, path);
				module = {path: path, packageName: location.name, file: location.file, members: []};
				modules.set(path, module);
			}
			return module.members;
		}
		for (decl in program.classes) {
			// A module's own variables are stored as the statics of a hidden class (`ModuleFields`): they are the module's.
			if (decl.name == ModuleFields.storageName(moduleName(decl.span))) {
				var members = moduleOf(decl.span);
				for (member in moduleVariables(decl))
					members.push(member);
				continue;
			}
			var described = classDeclaration(decl);
			if (described != null)
				types.push(described);
		}
		for (decl in program.interfaces)
			types.push(interfaceDeclaration(decl));
		for (decl in program.aliases)
			if (!decl.isPrivate)
				types.push(aliasDeclaration(decl));
		for (decl in program.enums)
			types.push(enumDeclaration(decl));
		for (decl in program.abstracts)
			types.push(abstractDeclaration(decl));
		// A module's functions are named after it (`pack.Mod.f`), except the entry module's `main`; none can be private.
		for (fn in program.functions) {
			var module = moduleName(fn.span),
				prefix = module + ".",
				name = StringTools.startsWith(fn.name, prefix) ? fn.name.substr(prefix.length) : fn.name,
				signature = semantic.signatures.get(fn.name) ?? fn;
			moduleOf(fn.span).push(moduleFunction(fn, name));
		}
		types.sort((left, right) -> Reflect.compare(left.path, right.path));
		// A module's variables and functions come from two lists; together they keep the order the source declares them in.
		var records = [for (module in modules) module];
		for (module in records)
			haxe.ds.ArraySort.sort(module.members,
				(left, right) -> left.source.position.line - right.source.position.line);
		records.sort((left, right) -> Reflect.compare(left.path, right.path));
		return {version: 1, described: described.copy(), modules: records, types: types};
	}

	/**
	 * The description of the type named `path` (canonical), as `model` gives it, built alone: what the editor shows for one
	 * declaration (`LanguageService`). Null for a private type or none of that name.
	 */
	public function typeNamed(path:String):Null<ApiDeclaration> {
		var tables = semantic.declarations;
		if (tables.classes.exists(path))
			return classDeclaration(tables.classes.get(path));
		if (tables.interfaces.exists(path))
			return interfaceDeclaration(tables.interfaces.get(path));
		if (tables.aliases.exists(path)) {
			var alias = tables.aliases.get(path);
			return alias.isPrivate ? null : aliasDeclaration(alias);
		}
		if (tables.enums.exists(path))
			return enumDeclaration(tables.enums.get(path));
		if (tables.abstracts.exists(path))
			return abstractDeclaration(tables.abstracts.get(path));
		return null;
	}

	/** The module-level function or variable `name` of the module `module`, as its module record holds it. */
	public function moduleMember(module:String, name:String):Null<ApiMember> {
		// The entry module's main is named main alone (`ModuleCanonicalizer.canonicalFunction`).
		var fn = semantic.signatures.get(module + "." + name);
		if (fn == null && name == "main") {
			var main = semantic.signatures.get("main");
			if (main != null && moduleName(main.span) == module)
				fn = main;
		}
		if (fn != null)
			return moduleFunction(fn, name);
		var storage = semantic.declarations.classes.exists(ModuleFields.storageName(module))
			? semantic.declarations.classes.get(ModuleFields.storageName(module)) : null;
		if (storage == null)
			return null;
		for (member in moduleVariables(storage))
			if (member.name == name)
				return member;
		return null;
	}

	/** A builder for describing declarations one at a time, from the semantic program an analysis keeps. */
	public static function of(semantic:SemanticProgram, modules:Map<String, ModuleState>):ApiModelBuilder
		return new ApiModelBuilder(semantic, modules, [], []);

	function moduleVariables(storage:AstClass):Array<ApiMember>
		return fields(ownerInfo(storage.name, storage.span, storage.typeParameters, storage.typeConstraints),
			storage.fields,
			true);

	function moduleFunction(fn:AstFunction, name:String):ApiMember
		return callable(fn, semantic.signatures.get(fn.name) ?? fn, name, "function", true, fn.name, new Map());

	function classDeclaration(decl:AstClass):Null<ApiDeclaration> {
		if (decl.isPrivate || AbstractStatics.abstractOf(decl.name) != null)
			return null;
		var owner = ownerInfo(decl.name, decl.span, decl.typeParameters, decl.typeConstraints),
			isExtern = decl.isExtern == true,
			publicByDefault = isExtern || has(decl.metadata, "publicFields"),
			members = fields(owner, decl.fields, publicByDefault);
		addMethods(members, owner, decl.methods, publicByDefault);
		return declaration(owner, isExtern ? "extern" : "class", decl.metadata, isExtern, members,
			decl.base == null ? [] : [decl.base], decl.interfaces);
	}

	function interfaceDeclaration(decl:AstInterface):ApiDeclaration {
		var owner = ownerInfo(decl.name, decl.span, decl.typeParameters, decl.typeConstraints),
			members = fields(owner, decl.fields, true);
		addMethods(members, owner, decl.methods, true);
		return declaration(owner, "interface", decl.documentationMetadata, false, members, decl.bases);
	}

	function aliasDeclaration(decl:AstTypeAlias):ApiDeclaration
		return declaration(ownerInfo(decl.name, decl.span, decl.typeParameters, decl.typeConstraints), "typedef",
			decl.metadata,
			false, [], null, null, decl.type);

	function enumDeclaration(decl:AstEnum):ApiDeclaration {
		var owner = ownerInfo(decl.name, decl.span, decl.typeParameters, decl.typeConstraints),
			scope = parametersIn(decl.name, decl.typeParameters),
			result = ApiTypeEncoder.encode(TInstance(compiler.types.Type.NominalKind.Enum, decl.name,
				[for (parameter in decl.typeParameters) scope.get(parameter)])),
			members:Array<ApiMember> = [for (entry in decl.cases) {
				source: source(entry.span, entry.metadata),
				kind: "enumConstructor",
				name: entry.name,
				isStatic: true,
				arguments: [for (parameter in entry.params) {
					name: parameter.name,
					type: typeOf(parameter.type,
						() -> semantic.declarations.declaredTypes.enumParameterType(parameter, scope),
						parameter.span,
						scope),
					optional: parameter.optional,
					defaultValue: null
				}],
				result: result,
				typeParameters: []
			}];
		addMethods(members, owner, decl.methods ?? [], true);
		return declaration(owner, "enum", decl.metadata, false, members, null, decl.conformances);
	}

	function abstractDeclaration(decl:AstAbstract):ApiDeclaration {
		var owner = ownerInfo(decl.name, decl.span, decl.typeParameters, decl.typeConstraints),
			isExtern = decl.isExtern == true,
			publicByDefault = isExtern || has(decl.metadata, "publicFields"),
			members = fields(owner, decl.fields, publicByDefault),
			storage = semantic.declarations.classes.exists(AbstractStatics.storageName(decl.name))
				? semantic.declarations.classes.get(AbstractStatics.storageName(decl.name)) : null;
		if (storage != null)
			members = members.concat(fields(ownerInfo(storage.name, storage.span, storage.typeParameters,
				storage.typeConstraints),
				storage.fields, publicByDefault));
		addMethods(members, owner, decl.methods, publicByDefault, true);
		if (decl.values != null) {
			var result:ApiType = {
				kind: "named",
				path: decl.name,
				arguments: [for (name in decl.typeParameters) ApiTypeEncoder.encode(TTypeParameter(decl.name, name))]
			};
			for (value in decl.values)
				if (value.isPublic != false)
					members.push({
						source: source(value.span, value.metadata),
						kind: "enumValue",
						name: value.name,
						isStatic: true,
						type: result
					});
		}
		return declaration(owner, "abstract", decl.metadata, isExtern, members, null, decl.conformances,
			decl.underlying,
			decl.fromTypes, decl.toTypes);
	}

	static function ownerInfo(name:String, span:SourceSpan, typeParameters:Array<String>,
			typeConstraints:Null<Array<AstTypeConstraint>>):ApiOwner
		return {name: name, span: span, typeParameters: typeParameters, typeConstraints: typeConstraints};

	function declaration(owner:ApiOwner, kind:String, metadata:Null<Array<AstMetadata>>, isExtern:Bool,
			members:Array<ApiMember>, ?supertypes:Array<AstType>, ?interfaces:Array<AstType>, ?underlying:AstType,
			?from:Array<AstType>, ?to:Array<AstType>):ApiDeclaration {
		// Members stay in the order the source declares them, which is how their author grouped them.
		var scope = parametersIn(owner.name, owner.typeParameters);
		return {
			source: source(owner.span, metadata),
			path: owner.name,
			module: moduleName(owner.span),
			packageName: locate(owner.span.file, moduleName(owner.span)).name,
			kind: kind,
			isExtern: isExtern,
			typeParameters: parameters(owner.typeParameters, owner.typeConstraints, scope),
			supertypes: resolveAll(supertypes, owner.span, scope),
			interfaces: resolveAll(interfaces, owner.span, scope),
			underlying: underlying == null ? null : resolve(underlying, owner.span, scope),
			from: resolveAll(from, owner.span, scope),
			to: resolveAll(to, owner.span, scope),
			members: members
		};
	}

	function fields(owner:ApiOwner, fields:Array<AstField>, publicByDefault:Bool):Array<ApiMember> {
		var members:Array<ApiMember> = [], scope = parametersIn(owner.name, owner.typeParameters);
		for (field in fields) {
			if (!(field.isPublic ?? publicByDefault))
				continue;
			var span = field.declarationSpan ?? field.span,
				type = typeOf(field.type, () -> semantic.declarations.types.fieldType(owner.name, field, scope), span,
					scope);
			if (field.readAccess == null && field.writeAccess == null)
				members.push({
					source: source(span, field.metadata),
					kind: "field",
					name: field.name,
					isStatic: field.isStatic,
					isFinal: field.isFinal,
					type: type,
					overrides: field.isStatic ? null : overridden(owner.name, field.name)
				});
			else
				members.push({
					source: source(span, field.metadata),
					kind: "property",
					name: field.name,
					isStatic: field.isStatic,
					type: type,
					get: access(field.readAccess),
					set: access(field.writeAccess),
					overrides: field.isStatic ? null : overridden(owner.name, field.name)
				});
		}
		return members;
	}

	function addMethods(members:Array<ApiMember>, owner:ApiOwner, methods:Array<AstFunction>, publicByDefault:Bool,
			isAbstract:Bool = false):Void {
		var declared = semantic.signaturesByOwner.get(owner.name);
		for (method in methods) {
			if (method.sourcePrivate == true || has(method.metadata, InterfaceFieldAccessors.GENERATED))
				continue;
			var isPublic = method.isPublic ?? (method.isOverride == true
				? inheritedVisibility(owner.name, method.name) : publicByDefault);
			var operatorText = isAbstract && method.isStatic ? annotationArguments(method.metadata, "op") : [],
				conversion = isAbstract && method.isStatic && has(method.metadata, "from") ? "from"
					: isAbstract && has(method.metadata, "to") ? "to" : null;
			if (!isPublic && operatorText.length == 0 && conversion == null)
				continue;
			var signature = declared == null ? method : declared.get(method.name) ?? method,
				member = callable(method, signature, method.name, method.name == "new" ? "constructor" : "method",
					method.isStatic, owner.name + "." + method.name, parametersIn(owner.name, owner.typeParameters),
					method.isStatic || method.name == "new" ? null : overridden(owner.name, method.name));
			if (isPublic)
				members.push(member);
			if (operatorText.length > 0)
				members.push({
					source: member.source, kind: "operator", name: operatorText[0], operatorText: operatorText[0],
					isStatic: method.isStatic,
					arguments: member.arguments, result: member.result, typeParameters: member.typeParameters
				});
			if (conversion != null)
				members.push({
					source: member.source, kind: "conversion", name: conversion, conversion: conversion,
					isStatic: method.isStatic,
					arguments: member.arguments, result: member.result, typeParameters: member.typeParameters
				});
		}
	}

	/**
	 * A method or a module's function as a member named `name`: `signature` is its checked declaration (inferred types
	 * filled), `method` the source one, and `qualified` owns its type parameters, added to the owner's `scope`.
	 */
	function callable(method:AstFunction, signature:AstFunction, name:String, kind:String, isStatic:Bool,
			qualified:String,
			scope:Map<String, CompilerType>, ?overrides:String):ApiMember {
		var scope = scope.copy();
		for (parameter in method.typeParameters ?? [])
			scope.set(parameter, TTypeParameter(qualified, parameter));
		var types = semantic.declarations.types,
			argumentTypes = types.argumentTypes(signature, scope);
		return {source: source(method.span, method.metadata),
			kind: kind,
			name: name,
			isStatic: isStatic,
			arguments: [for (index in 0...method.arguments.length) {
				var argument = method.arguments[index], optional = AstPredicates.isOptionalArgument(argument);
				{
					name:argument.name,
						type:typeOf(argument.type,
						() -> optional ? declaredOptional(argumentTypes[index]) : argumentTypes[index], argument.span,
						scope),
						optional:optional,
						defaultValue:argument.defaultValue == null ? null
						: sourceText(argument.defaultValueSpan ?? Parser.expressionSpan(argument.defaultValue))
				};
			}],
				result: typeOf(method.result, () -> types.resultType(signature, scope), method.span, scope),
				typeParameters: parameters(method.typeParameters ?? [], method.typeConstraints, scope),
				overrides: overrides};
	}

	/**
	 * The supertype whose member `name` the member `name` of `owner` overrides or implements, which documents it when it
	 * has no comment of its own: as Javadoc looks, the interfaces `owner` implements (each with its own bases) before its
	 * superclass chain. Null for a member that declares something new.
	 */
	function overridden(owner:String, name:String):Null<String> {
		for (supertype in directSupertypes(owner)) {
			if (declares(supertype, name))
				return supertype;
			var found = overridden(supertype, name);
			if (found != null)
				return found;
		}
		return null;
	}

	/**
	 * The comment that documents the instance member `name` of `owner` when it has none of its own: that of the member it
	 * overrides or implements, followed up the hierarchy as `overridden` finds it. Null when none has a comment.
	 */
	public function inheritedDocumentation(owner:String, name:String):Null<Documentation> {
		var current = owner;
		while (true) {
			var supertype = overridden(current, name);
			if (supertype == null)
				return null;
			var declared = instanceMember(supertype, name);
			var doc = declared == null ? null : commentAt(declared.span, declared.metadata);
			if (doc != null && doc.lines.length > 0)
				return doc;
			current = supertype;
		}
	}

	/** Where the class or interface `path` declares the instance member `name`, if it does. */
	function instanceMember(path:String, name:String):Null<{span:SourceSpan, metadata:Null<Array<AstMetadata>>}> {
		var tables = semantic.declarations, fields:Array<AstField> = [], methods:Array<AstFunction> = [];
		if (tables.classes.exists(path)) {
			fields = tables.classes.get(path).fields;
			methods = tables.classes.get(path).methods;
		} else if (tables.interfaces.exists(path)) {
			fields = tables.interfaces.get(path).fields;
			methods = tables.interfaces.get(path).methods;
		}
		for (field in fields)
			if (field.name == name && !field.isStatic)
				return {span: field.declarationSpan ?? field.span, metadata: field.metadata};
		for (method in methods)
			if (method.name == name && !method.isStatic)
				return {span: method.span, metadata: method.metadata};
		return null;
	}

	/** A class's or an interface's direct supertypes, its interfaces before its superclass. */
	function directSupertypes(path:String):Array<String> {
		var tables = semantic.declarations, types:Array<AstType> = [], span = null, scope = null;
		if (tables.classes.exists(path)) {
			var decl = tables.classes.get(path);
			types = decl.interfaces.concat(decl.base == null ? [] : [decl.base]);
			span = decl.span;
			scope = parametersIn(decl.name, decl.typeParameters);
		} else if (tables.interfaces.exists(path)) {
			var decl = tables.interfaces.get(path);
			types = decl.bases;
			span = decl.span;
			scope = parametersIn(decl.name, decl.typeParameters);
		}
		if (span == null || scope == null)
			return [];
		var paths:Array<String> = [];
		for (type in types)
			switch tables.resolve(type, span, scope) {
				case TInstance(_, resolved, _): paths.push(resolved);
				case _:
			}
		return paths;
	}

	function declares(path:String, name:String):Bool
		return instanceMember(path, name) != null;

	function inheritedVisibility(owner:String, name:String):Bool {
		var decl = semantic.declarations.classes.get(owner);
		while (decl != null && decl.base != null) {
			var path = switch semantic.declarations.resolve(decl.base, decl.span,
				parametersIn(decl.name, decl.typeParameters)) {
					case TInstance(_, path, _): path;
					default: break;
				};
			decl = semantic.declarations.classes.get(path);
			var methods = semantic.signaturesByOwner.get(path), method = methods == null ? null : methods.get(name);
			if (method != null && (method.isPublic != null || method.isOverride != true))
				return method.isPublic == true;
		}
		return true;
	}

	function parameters(names:Array<String>, constraints:Null<Array<AstTypeConstraint>>,
			scope:Map<String, CompilerType>):Array<ApiTypeParameter>
		return [for (name in names) {
			name: name,
			constraints: [for (constraint in constraints ?? [])
				if (constraint.parameter == name) resolve(constraint.type, constraint.span, scope)]
		}];

	static function parametersIn(owner:String, parameters:Array<String>):Map<String, CompilerType>
		return [for (name in parameters) name => TTypeParameter(owner, name)];

	function resolveAll(types:Null<Array<AstType>>, span:SourceSpan, scope:Map<String, CompilerType>):Array<ApiType>
		return [for (type in types ?? []) resolve(type, span, scope)];

	function resolve(type:AstType, span:SourceSpan, scope:Map<String, CompilerType>):ApiType
		return typeOf(type, () -> semantic.declarations.resolve(type, span, scope), span, scope);

	/**
	 * The type `written` in the source as a reader should see it: a typedef it names stays that name (`ButtonOptions`, not
	 * its fields), as do typedefs named inside it, with everything else resolved as the typer resolved it; the typedef's own
	 * declaration carries what it stands for. Where nothing is written (an inferred type) `resolved` gives the checked type.
	 * Names are canonical here, so a name is the typedef's when the declaration index has a typedef of that name and no type
	 * parameter in scope takes it.
	 */
	function typeOf(written:Null<AstType>, resolved:() -> CompilerType, span:SourceSpan,
			scope:Map<String, CompilerType>,
			depth:Int = 0):ApiType {
		inline function inner(type:AstType):ApiType
			return typeOf(type, () -> semantic.declarations.resolve(type, span, scope), span, scope, depth + 1);
		var aliases = semantic.declarations.aliases;
		return switch written {
			case null | InferredType | ErrorType(_):
				ApiTypeEncoder.encode(resolved());
			case NamedType(name) if (!scope.exists(name) && aliases.exists(name)):
				{kind: "named", path: name, arguments: []};
			case AppliedType(name, arguments) if (!scope.exists(name) && aliases.exists(name)):
				{kind: "named", path: name, arguments: [for (argument in arguments) inner(argument)]};
			// Haxe's structural iteration types resolve to their method structure; a reader knows them by name.
			case AppliedType(name = "Iterator" | "Iterable" | "KeyValueIterator" | "KeyValueIterable", arguments)
				if (!scope.exists(name)):
				{kind: "builtin", path: name, arguments: [for (argument in arguments) inner(argument)]};
			case AppliedType(_, arguments):
				// A generic class, abstract or container: the resolved head, with the arguments as written when it keeps them.
				var head = ApiTypeEncoder.encode(resolved());
				head.arguments != null && head.arguments.length == arguments.length
					&& (head.kind == "named" || head.kind == "builtin") ? {
						kind: head.kind,
						path: head.path,
						arguments: [for (argument in arguments) inner(argument)]
					} : head;
			case ArrayType(element):
				{kind: "builtin", path: "Array", arguments: [inner(element)]};
			case MapType(key, value):
				{kind: "builtin", path: "Map", arguments: [inner(key), inner(value)]};
			case NullableType(element):
				{kind: "builtin", path: "Null", arguments: [inner(element)]};
			case FunctionType(arguments, result, optional):
				{
					kind: "function",
					arguments: [for (argument in arguments) inner(argument)],
					optional: [for (index in 0...arguments.length) index < optional.length && optional[index]],
					result: inner(result)
				};
			case AnonymousType(fields):
				var ordered = fields.copy();
				ordered.sort((left, right) -> Reflect.compare(left.name, right.name));
				{
					kind:"anonymous",
						id:depth,
						fields:[for (field in ordered) {
							name: field.name,
							type: inner(field.type),
							optional: field.optional,
							isFinal: field.isFinal
						}]
				};
			case _:
				ApiTypeEncoder.encode(resolved());
		};
	}

	/** An optional argument's checked type is `Null<T>`; the model gives the type as declared, `T`, beside `optional`. */
	static function declaredOptional(type:CompilerType):CompilerType
		return switch type {
			case TNullable(element): element;
			case _: type;
		};

	/** The doc comment of the declaration at `span`, written before it or before its first annotation. */
	function commentAt(span:SourceSpan, metadata:Null<Array<AstMetadata>>):Documentation {
		var file = span.file, scanned = comments.get(file);
		if (scanned == null) {
			scanned = DocumentationTools.scan(file);
			comments.set(file, scanned);
		}
		var doc = DocumentationTools.forSpan(file, scanned, span);
		if (doc.lines.length == 0 && metadata != null && metadata.length > 0 && metadata[0].span.file == file)
			doc = DocumentationTools.forSpan(file, scanned, metadata[0].span);
		return doc;
	}

	function source(span:SourceSpan, metadata:Null<Array<AstMetadata>>):ApiSource {
		var file = span.file, doc = commentAt(span, metadata), annotations:Array<ApiModel.ApiAnnotation> = [];
		for (entry in metadata ?? []) {
			switch entry.name {
				case "deprecated" | "noCompletion":
					annotations.push({
						name: entry.name,
						arguments: [for (argument in entry.arguments) expressionText(argument)]
					});
				case "dox" if (entry.arguments.length == 1 && expressionText(entry.arguments[0]) == "hide"):
					annotations.push({name: entry.name, arguments: ["hide"]});
				default:
			}
		}
		return {
			visibility: "public",
			position: {file: locate(file, moduleName(span)).file, line: file.lineAt(span.start)},
			documentation: doc.lines.length == 0 ? null : DocumentationTools.forApi(doc),
			metadata: annotations
		};
	}

	/** The package `file` belongs to, if any, and its path relative to that package's root, or else to its source root. */
	function locate(file:SourceFile, module:String):{name:Null<String>, file:String} {
		var path = absolute(file.physicalPath);
		for (entry in packages)
			if (StringTools.startsWith(path, entry.root))
				return {name: entry.name, file: path.substr(entry.root.length)};
		return {name: null, file: relativeFile(path, module)};
	}

	function relativeFile(path:String, module:String):String {
		for (root in roots)
			if (StringTools.startsWith(path, root))
				return path.substr(root.length);
		var logical = module.split(".").join("/") + ".hx";
		return StringTools.endsWith(path, "/" + logical) ? logical : Path.withoutDirectory(path);
	}

	function moduleName(span:SourceSpan):String
		return modules.get(span.file.path) ?? ModulePath.fromFile(Path.withoutDirectory(span.file.path));

	static function absolute(path:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));

	static function expressionText(expression:AstExpression):String {
		return sourceText(Parser.expressionSpan(expression));
	}

	static function sourceText(span:SourceSpan):String
		return span.file.slice(span.start, span.end);

	static function has(metadata:Null<Array<AstMetadata>>, name:String):Bool {
		for (entry in metadata ?? [])
			if (entry.name == name)
				return true;
		return false;
	}

	static function annotationArguments(metadata:Null<Array<AstMetadata>>, name:String):Array<String> {
		for (entry in metadata ?? [])
			if (entry.name == name)
				return [for (argument in entry.arguments) expressionText(argument)];
		return [];
	}

	static function access(policy:Null<AstFieldAccess>):String
		return switch policy {
			case null | DefaultAccess: "default";
			case NullAccess: "null";
			case NeverAccess: "never";
			case GetAccess: "get";
			case SetAccess: "set";
			case DynamicAccess: "dynamic";
		};
}
