package compiler.service;

import compiler.semantic.ModuleCanonicalizer;
import compiler.syntax.Ast.AstType;
import compiler.Diagnostic;
import compiler.Source.SourceSpan;
import compiler.syntax.Token.TokenKind;
import compiler.Compiler;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticModel;
import compiler.Compiler.CompileResult;
import compiler.types.Type.CompilerType;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.TypeRelations;
import compiler.runtime.RuntimeNatives;

/** Editor-facing declaration summary, optionally marked as stale. */
typedef DocumentSymbol = {
	final ?revision:Int;
	final ?stale:Bool;
	final name:String;
	final kind:String;
	final detail:String;
	final span:SourceSpan;
}

/** Editor completion candidate derived from the effective compiler snapshot. */
typedef CompletionItem = {
	final ?revision:Int;
	final ?stale:Bool;
	final label:String;
	final kind:String;
	final detail:String;
	final ?sortText:String;
	final ?insertText:String;
}

/** Source location returned by a semantic navigation query. */
typedef SymbolLocation = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
}

/** Revision-aware source replacement proposed by an editor operation. */
typedef TextEdit = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
	final replacement:String;
}

typedef SignatureHelp = {
	final label:String;
	final parameters:Array<String>;
	final activeParameter:Int;
	final ?revision:Int;
	final ?stale:Bool;
}

private typedef SemanticQueryContext = {
	final state:ModuleState;
	final model:SemanticModel;
	final symbol:Null<SemanticSymbolId>;
	final completion:SemanticCompletionContext;
	final stale:Bool;
}

/** Read-only editor queries backed by the persistent compiler state. */
class LanguageService {
	static inline final MAX_COMPLETION_ITEMS = 200;
	static inline final MAX_REFERENCE_RESULTS = 10000;

	public final compiler:Compiler;

	public function new(?identityState:haxe.io.Bytes)
		compiler = new Compiler(identityState, RuntimeNatives.configuration());

	public function update(path:String, source:String):ModuleState
		return compiler.update(path, source);

	public function remove(path:String):Bool
		return compiler.remove(path);

	public function configure(identity:String):Void
		compiler.configure(identity);

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult
		return compiler.compile(entryModule, token);

	public function analyze(entryModule:String, ?token:CancellationToken):compiler.Compiler.AnalysisResult
		return compiler.analyze(entryModule, token);

	public function validate(path:String, source:String, entryModule:String, ?token:CancellationToken):compiler.Compiler.ValidationResult
		return compiler.validate(path, source, entryModule, token);

	public function diagnostics(path:String):Array<Diagnostic> {
		var state = stateFor(path);
		return state == null ? [] : state.diagnostics.copy();
	}

	/** Whether editor spans and typed data belong to the latest source revision. */
	public function isCurrent(path:String):Bool {
		var state = stateFor(path);
		return state != null && state.ast != null && state.lastGoodRevision == state.revision;
	}

	public function documentSymbols(path:String):Array<DocumentSymbol> {
		var state = stateFor(path),
			result:Array<DocumentSymbol> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return result;
		for (fn in ast.functions)
			result.push({
				name: fn.name,
				kind: "function",
				detail: '${fn.name}():${typeName(fn.result)}',
				span: fn.span
			});
		for (alias in ast.aliases)
			result.push({
				name: alias.name,
				kind: "type",
				detail: 'typedef ${alias.name}${alias.typeParameters.length == 0 ? "" : "<" + alias.typeParameters.join(",") + ">"}=${typeName(alias.type)}',
				span: alias.span
			});
		for (interfaceDecl in ast.interfaces) {
			result.push({
				name: interfaceDecl.name,
				kind: "interface",
				detail: 'interface ${interfaceDecl.name}',
				span: interfaceDecl.span
			});
			for (method in interfaceDecl.methods)
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
		}
		for (enumDecl in ast.enums) {
			result.push({
				name: enumDecl.name,
				kind: "enum",
				detail: 'enum ${enumDecl.name}',
				span: enumDecl.span
			});
			for (caseDecl in enumDecl.cases)
				result.push({
					name: caseDecl.name,
					kind: "enumCase",
					detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})',
					span: caseDecl.span
				});
		}
		for (classDecl in ast.classes) {
			result.push({
				name: classDecl.name,
				kind: "class",
				detail: 'class ${classDecl.name}',
				span: classDecl.span
			});
			for (field in classDecl.fields)
				result.push({
					name: field.name,
					kind: "field",
					detail: '${field.name}:${typeName(field.type)}',
					span: field.span
				});
			for (method in classDecl.methods)
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
		}
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		tagResults(result, state);
		return result;
	}

	public function complete(path:String, position:Int, ?token:CancellationToken):Array<CompletionItem> {
		if (token != null)
			token.check();
		var state = stateFor(path),
			result:Array<CompletionItem> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return result;
		var prefix = identifierPrefix(state.source.text, position);
		var qualifier = memberQualifier(state.source.text, position),
			model = effectiveSemanticModel(state),
			semanticContext = model == null ? null : model.index.completionContext(position, qualifier);
		if (qualifier != null) {
			if (semanticContext != null && semanticContext.receiver != null)
				addInstanceMembers(semanticContext.receiver, prefix, result);
			if (model != null)
				for (symbol in compiler.semanticWorkspace.visibleSymbols(state, token)) {
					var separator = symbol.name.lastIndexOf(".");
					if (symbol.kind == DeclarationKind.EnumCase
						&& separator > 0
						&& sourceName(symbol.name.substring(0, separator)) == qualifier)
						addMember(symbol.name.substring(separator + 1), "enumCase", symbol.name, prefix, result);
				}
			for (enumDecl in ast.enums)
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases)
						if (prefix.length == 0 || StringTools.startsWith(caseDecl.name, prefix))
							result.push({
								label: caseDecl.name,
								kind: "enumCase",
								detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})'
							});
			for (classDecl in ast.classes)
				if (classDecl.name == qualifier) {
					for (field in classDecl.fields)
						if (field.isStatic && (prefix.length == 0 || StringTools.startsWith(field.name, prefix)))
							result.push({label: field.name, kind: "field", detail: '${field.name}:${typeName(field.type)}'});
					for (method in classDecl.methods)
						if (method.isStatic && (prefix.length == 0 || StringTools.startsWith(method.name, prefix)))
							result.push({
								label: method.name,
								kind: "method",
								detail: '${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}'
							});
				}
			if (result.length > 0) {
				sortCompletion(result);
				tagResults(result, state);
				return limitedCompletion(result);
			}
		}
		if (semanticContext != null)
			for (local in semanticContext.locals)
				addMember(local.name, "variable", local.name + ":" + compilerTypeName(local.type), prefix,
					result, semanticContext.expected != null && completionTypeCompatible(local.type, semanticContext.expected) ? 0 : 2);
		if (semanticContext != null && semanticContext.expected != null)
			for (symbol in compiler.semanticWorkspace.enumCases(semanticContext.expected, token)) {
				var label = sourceName(symbol.name),
					signature = compiler.semanticWorkspace.indexedSignature(symbol.id),
					insertText = signature != null && signature.parameters.length > 0 ? label + "(" : label;
				addMember(label, "enumCase", symbol.name, prefix, result, 1, insertText);
			}
		if (model != null)
			for (symbol in compiler.semanticWorkspace.visibleSymbols(state, token))
				if (symbol.name.indexOf(".") < 0) {
					var signature = compiler.semanticWorkspace.indexedSignature(symbol.id);
					addMember(symbol.name, completionDeclarationKind(symbol.kind), symbol.name, prefix, result, 3,
						signature == null ? null : symbol.name + "(");
				}
		for (symbol in documentSymbols(path))
			addMember(symbol.name, symbol.kind, symbol.detail, prefix, result);
		sortCompletion(result);
		tagResults(result, state);
		return limitedCompletion(result);
	}

	public function hover(path:String, position:Int):Null<String> {
		var state = stateFor(path),
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return null;
		var model = effectiveSemanticModel(state),
			indexedId = model == null ? null : model.index.symbolIdAt(position),
			indexedSignature = indexedId == null ? null : compiler.semanticWorkspace.indexedSignature(indexedId);
		if (indexedSignature != null)
			return indexedSignature.label;
		var name = identifierPrefix(state.source.text, position);
		if (name.length == 0)
			return null;
		var qualifier = memberQualifier(state.source.text, position);
		if (qualifier != null) {
			for (enumDecl in ast.enums)
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases)
						if (caseDecl.name == name)
							return
								'${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) (param.optional ? "?" : "") + typeName(param.type)].join(",")})';
			for (classDecl in ast.classes)
				if (classDecl.name == qualifier)
					for (field in classDecl.fields)
						if (field.name == name && field.isStatic)
							return '${field.name}:${typeName(field.type)}';
			var model = effectiveSemanticModel(state),
				context = model == null ? null : model.index.completionContext(position, qualifier),
				members:Array<CompletionItem> = [];
			if (context != null && context.receiver != null) {
				addInstanceMembers(context.receiver, name, members);
				if (members.length > 0)
					return members[0].detail;
			}
		}
		for (symbol in documentSymbols(path))
			if (symbol.name == name)
				return symbol.detail;
		return null;
	}

	public function signatureHelp(path:String, position:Int):Null<SignatureHelp> {
		var state = stateFor(path),
			tokens = state == null ? null : effectiveTokens(state),
			model = state == null ? null : effectiveSemanticModel(state);
		if (state == null || tokens == null || model == null)
			return null;
		var open = callOpenToken(tokens, position);
		if (open < 1)
			return null;
		var callee = open - 1;
		while (callee >= 0 && tokens[callee].kind != Identifier)
			callee--;
		if (callee < 0)
			return null;
		var id = model.index.symbolIdAt(tokens[callee].span.start + 1),
			signature = id == null ? null : compiler.semanticWorkspace.indexedSignature(id);
		if (signature == null)
			return null;
		var active = activeCallParameter(tokens, open, position);
		if (signature.parameters.length > 0 && active >= signature.parameters.length)
			active = signature.parameters.length - 1;
		var result:SignatureHelp = {
			label: signature.label,
			parameters: signature.parameters,
			activeParameter: active
		};
		tagResults([result], state);
		return result;
	}

	static function callOpenToken(tokens:Array<compiler.syntax.Token>, position:Int):Int {
		var depth = 0;
		var index = tokens.length - 1;
		while (index >= 0 && tokens[index].span.start >= position)
			index--;
		while (index >= 0) {
			switch tokens[index].kind {
				case RightParen:
					depth++;
				case LeftParen:
					if (depth == 0)
						return index;
					depth--;
				default:
			}
			index--;
		}
		return -1;
	}

	static function activeCallParameter(tokens:Array<compiler.syntax.Token>, open:Int, position:Int):Int {
		var depth = 0, active = 0;
		for (index in open + 1...tokens.length) {
			var token = tokens[index];
			if (token.span.start >= position)
				break;
			switch token.kind {
				case LeftParen, LeftBracket, LeftBrace:
					depth++;
				case RightParen, RightBracket, RightBrace:
					if (depth > 0)
						depth--;
				case Comma:
					if (depth == 0)
						active++;
				default:
			}
		}
		return active;
	}

	public function definition(path:String, position:Int):Null<SymbolLocation> {
		return indexedDefinition(path, position);
	}

	function indexedDefinition(path:String, position:Int):Null<SymbolLocation> {
		var context = semanticQuery(path, position);
		if (context == null)
			return null;
		var resolved = context.symbol == null ? null : compiler.semanticWorkspace.indexedSymbol(context.symbol);
		return resolved == null ? null : {
			path: resolved.symbol.declaration.file.path,
			span: resolved.symbol.declaration,
			revision: snapshotRevision(resolved.state),
			stale: snapshotRevision(resolved.state) != resolved.state.revision
		};
	}

	public function references(path:String, position:Int, ?token:CancellationToken):Array<SymbolLocation> {
		var indexed = indexedReferences(path, position, token);
		return indexed == null ? [] : indexed;
	}

	function indexedReferences(path:String, position:Int, ?token:CancellationToken):Null<Array<SymbolLocation>> {
		var context = semanticQuery(path, position);
		if (context == null)
			return null;
		var id = context.symbol;
		if (id == null)
			return null;
		var result:Array<SymbolLocation> = [
			for (location in compiler.semanticWorkspace.indexedLocations(id, token))
				{
					path: location.span.file.path,
					span: location.span,
					revision: snapshotRevision(location.state),
					stale: snapshotRevision(location.state) != location.state.revision
				}
		];
		result.sort(function(left, right) {
			var path = Reflect.compare(left.path, right.path);
			return path == 0 ? Reflect.compare(left.span.start, right.span.start) : path;
		});
		return result.length > MAX_REFERENCE_RESULTS ? result.slice(0, MAX_REFERENCE_RESULTS) : result;
	}

	public function rename(path:String, position:Int, replacement:String):Array<TextEdit> {
		var context = semanticQuery(path, position),
			indexedId = context == null ? null : context.symbol,
			name = symbolAt(path, position),
			result:Array<TextEdit> = [];
		if (indexedId == null || name == null || !isIdentifier(replacement) || replacement == name)
			return result;
		var targetReferences = references(path, position);
		if (indexedRenameCollides(indexedId, replacement, targetReferences))
			return result;
		for (reference in targetReferences)
			result.push({
				path: reference.path,
				span: reference.span,
				replacement: replacement,
				revision: reference.revision,
				stale: reference.stale
			});
		return result;
	}

	function indexedRenameCollides(target:SemanticSymbolId, replacement:String, affected:Array<SymbolLocation>):Bool {
		var affectedPaths:Map<String, Bool> = [];
		for (location in affected)
			affectedPaths.set(location.path, true);
		for (state in compiler.modules) {
			if (!affectedPaths.exists(state.source.path))
				continue;
			var tokens = effectiveTokens(state),
				model = effectiveSemanticModel(state);
			if (tokens != null && model != null)
				for (token in tokens)
					if (token.kind == Identifier && token.text == replacement) {
						var existing = model.index.symbolIdAt(token.span.start + 1);
						if (existing != null && Std.string(existing) != Std.string(target) && semanticNamesCollide(target, existing))
							return true;
					}
		}
		return false;
	}

	function semanticNamesCollide(left:SemanticSymbolId, right:SemanticSymbolId):Bool {
		var leftSymbol = compiler.semanticWorkspace.indexedSymbol(left),
			rightSymbol = compiler.semanticWorkspace.indexedSymbol(right);
		if (leftSymbol == null || rightSymbol == null)
			return false;
		var leftLocal = localCollisionScope(left),
			rightLocal = localCollisionScope(right);
		if (leftLocal != null || rightLocal != null)
			return leftLocal != null && leftLocal == rightLocal;
		if (leftSymbol.symbol.kind == DeclarationKind.Member && rightSymbol.symbol.kind == DeclarationKind.Member)
			return declarationOwner(leftSymbol.symbol.name) == declarationOwner(rightSymbol.symbol.name);
		return leftSymbol.state.name == rightSymbol.state.name;
	}

	static function localCollisionScope(id:SemanticSymbolId):Null<String> {
		var value = Std.string(id), marker = value.indexOf(":local:");
		if (marker < 0)
			return null;
		var identity = value.indexOf(":$" + "l", marker + 7);
		return identity < 0 ? value : value.substring(0, identity);
	}

	static function declarationOwner(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(0, separator);
	}

	function symbolAt(path:String, position:Int):Null<String> {
		var state = stateFor(path);
		var tokens = state == null ? null : effectiveTokens(state);
		if (state == null || tokens == null)
			return null;
		for (token in tokens)
			if (token.kind == Identifier && position >= token.span.start && position <= token.span.end)
				return token.text;
		return null;
	}

	static function isIdentifier(value:String):Bool {
		if (value.length == 0 || !isIdentifierStart(value.charCodeAt(0)))
			return false;
		for (i in 1...value.length)
			if (!isIdentifierPart(value.charCodeAt(i)))
				return false;
		return true;
	}

	function semanticQuery(path:String, position:Int, ?qualifier:String):Null<SemanticQueryContext> {
		var state = stateFor(path),
			model = state == null ? null : effectiveSemanticModel(state);
		return state == null || model == null ? null : {
			state: state,
			model: model,
			symbol: model.index.symbolIdAt(position),
			completion: model.index.completionContext(position, qualifier),
			stale: snapshotRevision(state) != state.revision
		};
	}

	static function sourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substring(separator + 1);
	}

	static function completionDeclarationKind(kind:DeclarationKind):String
		return switch kind {
			case DeclarationKind.Alias: "type";
			case DeclarationKind.EnumCase: "enumCase";
			default: Std.string(kind);
		};

	function addInstanceMembers(type:CompilerType, prefix:String, result:Array<CompletionItem>):Void {
		switch type {
			case TNullable(element):
				addInstanceMembers(element, prefix, result);
			case TInstance(Class, name, []):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast != null)
						for (classDecl in ast.classes)
							if (classDecl.name == name) {
								for (field in classDecl.fields)
									if (!field.isStatic)
										addMember(field.name, "field", '${field.name}:${typeName(field.type)}', prefix, result);
								for (method in classDecl.methods)
									if (!method.isStatic)
										addMember(method.name, "method",
											'${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}',
											prefix, result);
								if (classDecl.base != null)
									addInstanceMembers(TInstance(Class, ModuleCanonicalizer.astTypeName(classDecl.base), []), prefix, result);
							}
				}
			case TInstance(Interface, name, []):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast != null)
						for (interfaceDecl in ast.interfaces)
							if (interfaceDecl.name == name)
								for (method in interfaceDecl.methods)
									addMember(method.name, "method",
										'${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}',
										prefix, result);
				}
			case TArray(_):
				addMember("length", "field", "length:Int", prefix, result);
				addMember("copy", "method", "copy():Array", prefix, result);
				addMember("concat", "method", "concat(other):Array", prefix, result);
				addMember("slice", "method", "slice(start,end):Array", prefix, result);
				addMember("indexOf", "method", "indexOf(value):Int", prefix, result);
				addMember("push", "method", "push(value):Int", prefix, result);
				addMember("pop", "method", "pop():Element", prefix, result);
			case TMap(_, _):
				addMember("set", "method", "set(key,value):Void", prefix, result);
				addMember("exists", "method", "exists(key):Bool", prefix, result);
				addMember("keys", "method", "keys():Array", prefix, result);
				addMember("values", "method", "values():Array", prefix, result);
				addMember("remove", "method", "remove(key):Bool", prefix, result);
				addMember("clear", "method", "clear():Void", prefix, result);
				addMember("size", "method", "size():Int", prefix, result);
			case TString:
				addMember("length", "field", "length:Int", prefix, result);
				addMember("indexOf", "method", "indexOf(needle):Int", prefix, result);
				addMember("substring", "method", "substring(start,end):String", prefix, result);
			default:
		}
	}

	static function addMember(label:String, kind:String, detail:String, prefix:String, result:Array<CompletionItem>, ?rank:Int = 3, ?insertText:String):Void {
		if ((prefix.length == 0 || StringTools.startsWith(label, prefix)) && [for (item in result) item.label].indexOf(label) < 0)
			result.push({
				label: label,
				kind: kind,
				detail: detail,
				sortText: Std.string(rank) + "_" + label,
				insertText: insertText
			});
	}

	static function sortCompletion(result:Array<CompletionItem>):Void
		result.sort(function(left, right) return Reflect.compare(left.sortText, right.sortText));

	static function limitedCompletion(result:Array<CompletionItem>):Array<CompletionItem>
		return result.length > MAX_COMPLETION_ITEMS ? result.slice(0, MAX_COMPLETION_ITEMS) : result;

	static function completionTypeCompatible(actual:CompilerType, expected:CompilerType):Bool {
		if (TypeRelations.equals(actual, expected))
			return true;
		return switch expected {
			case TDynamic: true;
			case TNullable(element): completionTypeCompatible(actual, element);
			default: false;
		};
	}

	static function tagResults<T>(results:Array<T>, state:ModuleState):Void {
		var revision = snapshotRevision(state),
			stale = revision != state.revision;
		for (result in results) {
			Reflect.setField(result, "revision", revision);
			Reflect.setField(result, "stale", stale);
		}
	}

	static function snapshotRevision(state:ModuleState):Int
		return state.ast == null ? state.lastGoodRevision : state.revision;

	function stateFor(path:String):Null<ModuleState>
		return compiler.modules.get(ModulePath.fromFile(path));

	static function effectiveAst(state:ModuleState):Null<compiler.syntax.Ast.AstProgram>
		return state.ast == null ? state.lastGoodAst : state.ast;

	static function effectiveTokens(state:ModuleState):Null<Array<compiler.syntax.Token>>
		return state.ast == null ? state.lastGoodTokens : state.tokens;

	static function effectiveSemanticModel(state:ModuleState):Null<compiler.semantic.SemanticModel>
		return state.ast == null ? state.lastGoodSemanticModel : state.semanticModel;

	static function identifierPrefix(source:String, position:Int):String {
		var end = position < 0 ? 0 : position > source.length ? source.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.charCodeAt(start - 1)))
			start--;
		return source.substring(start, end);
	}

	static function memberQualifier(source:String, position:Int):Null<String> {
		var end = position < 0 ? 0 : position > source.length ? source.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.charCodeAt(start - 1)))
			start--;
		if (start == 0 || source.charAt(start - 1) != ".")
			return null;
		var qualifierEnd = start - 1, qualifierStart = qualifierEnd;
		while (qualifierStart > 0 && isIdentifierPart(source.charCodeAt(qualifierStart - 1)))
			qualifierStart--;
		return source.substring(qualifierStart, qualifierEnd);
	}

	static inline function isIdentifierPart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || code == 95;

	static inline function isIdentifierStart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

	static function typeName(type:AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(declaration, tag): '$declaration<"$tag">';
			case NamedType(name): name;
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) typeName(argument)].join(",")}>';
			case ArrayType(element): 'Array<${typeName(element)}>';
			case MapType(key, value): 'Map<${typeName(key)},${typeName(value)}>';
			case NullableType(element): 'Null<${typeName(element)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) typeName(argument)].join(",")})->${typeName(result)}';
			case AnonymousType(fields): '{${[for (field in fields) (field.optional ? "?" : "") + field.name + ":" + typeName(field.type)].join(",")}}';
		};

	static function compilerTypeName(type:CompilerType):String
		return switch type {
			case TInt: "Int";
			case TFloat: "Float";
			case TBool: "Bool";
			case TString: "String";
			case TVoid: "Void";
			case TArray(element): 'Array<${compilerTypeName(element)}>';
			case TMap(key, value): 'Map<${compilerTypeName(key)},${compilerTypeName(value)}>';
			case TNullable(element): 'Null<${compilerTypeName(element)}>';
			case TInstance(_, name, arguments): arguments.length == 0 ? name : name
					+ "<"
					+ [for (argument in arguments) compilerTypeName(argument)].join(",") + ">";
			case TFunction(arguments, result): "(" + [for (argument in arguments) compilerTypeName(argument)].join(",") + ")->" + compilerTypeName(result);
			default: Std.string(type);
		};
}
