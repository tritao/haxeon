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
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.ConditionalCompilation;
import compiler.Diagnostic.CompileError;

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
	final ?identity:String;
	final ?importPath:String;
}

typedef ResolvedCompletion = {
	final detail:String;
	final documentation:String;
	final edits:Array<TextEdit>;
}

typedef SymbolDocumentation = {
	final markdown:String;
	final parameters:Map<String, String>;
	final deprecated:Bool;
}

typedef CompletionResult = {
	final items:Array<CompletionItem>;
	final isIncomplete:Bool;
}

/** A same-document semantic occurrence, classified for LSP highlighting. */
typedef DocumentHighlight = {
	final span:SourceSpan;
	final write:Bool;
}

/** Absolute semantic token; transport adapters own position/delta encoding. */
typedef SemanticToken = {
	final span:SourceSpan;
	final type:String;
	final modifiers:Array<String>;
}

typedef CodeAction = {
	final id:String;
	final title:String;
	final diagnostic:Diagnostic;
	final edits:Array<TextEdit>;
}

typedef WorkspaceSymbol = {
	final identity:String;
	final name:String;
	final kind:String;
	final ?container:String;
	final detail:String;
	final path:String;
	final span:SourceSpan;
	final revision:Int;
	final ?documentation:String;
	final ?deprecated:Bool;
}

typedef InlayHint = {
	final position:Int;
	final label:String;
	final kind:String;
	final paddingLeft:Bool;
	final paddingRight:Bool;
}

typedef CallHierarchyItem = {
	final identity:String;
	final name:String;
	final kind:String;
	final detail:String;
	final path:String;
	final span:SourceSpan;
	final revision:Int;
	final ?documentation:String;
}

typedef CallHierarchyRelation = {
	final item:CallHierarchyItem;
	final ranges:Array<SourceSpan>;
}

typedef FoldingRegion = {
	final span:SourceSpan;
	final ?kind:String;
}

typedef DocumentLink = {
	final span:SourceSpan;
	final targetPath:String;
	final tooltip:String;
}

private typedef StructuralIndexEntry = {
	final revision:Int;
	final folds:Array<FoldingRegion>;
	final containers:Array<SourceSpan>;
}

private typedef WorkspaceIndexEntry = {
	final revision:Int;
	final symbols:Array<WorkspaceSymbol>;
}

private typedef DocumentationIndexEntry = {
	final revision:Int;
	final comments:Array<{end:Int, documentation:SymbolDocumentation}>;
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
	final ?documentation:String;
	final ?parameterDocumentation:Array<Null<String>>;
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
	final workspaceIndex:Map<String, WorkspaceIndexEntry> = [];
	final documentationIndex:Map<String, DocumentationIndexEntry> = [];
	final structuralIndex:Map<String, StructuralIndexEntry> = [];
	var editorDefines:Map<String, String> = [];

	public function new(?identityState:haxe.io.Bytes)
		compiler = new Compiler(identityState, RuntimeNatives.configuration());

	public function update(path:String, source:String):ModuleState
		return compiler.update(path, source);

	public function remove(path:String):Bool
		return compiler.remove(path);

	public function configure(identity:String, scopeIdentity:String, defines:Array<String>):Void {
		editorDefines = [for (define in defines) define => "1"];
		workspaceIndex.clear();
		documentationIndex.clear();
		structuralIndex.clear();
		compiler.configure(identity, scopeIdentity, defines);
	}

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

	public function codeActions(path:String, start:Int, end:Int):Array<CodeAction> {
		var state = stateFor(path), result:Array<CodeAction> = [];
		if (state == null)
			return result;
		for (diagnostic in state.diagnostics) {
			if (diagnostic.span.end < start || diagnostic.span.start > end)
				continue;
			for (fix in diagnostic.fixes)
				result.push({
					id: diagnostic.code + ":" + fix.id,
					title: fix.title,
					diagnostic: diagnostic,
					edits: [for (edit in fix.edits) {
						path: edit.span.file.path,
						span: edit.span,
						replacement: edit.replacement,
						revision: state.revision,
						stale: false
					}]
				});
		}
		return result;
	}

	public function workspaceSymbols(query:String, ?token:CancellationToken):Array<WorkspaceSymbol> {
		var normalized = query.toLowerCase(), result:Array<WorkspaceSymbol> = [];
		for (state in compiler.modules) {
			if (token != null)
				token.check();
			for (symbol in indexedWorkspaceSymbols(state))
				if (normalized.length == 0 || symbol.name.toLowerCase().indexOf(normalized) >= 0)
					result.push(symbol);
		}
		result.sort(function(left, right) {
			var leftPrefix = StringTools.startsWith(left.name.toLowerCase(), normalized), rightPrefix = StringTools.startsWith(right.name.toLowerCase(), normalized);
			if (leftPrefix != rightPrefix)
				return leftPrefix ? -1 : 1;
			var name = Reflect.compare(left.name, right.name);
			return name == 0 ? Reflect.compare(left.identity, right.identity) : name;
		});
		return result.length > 200 ? result.slice(0, 200) : result;
	}

	public function resolveWorkspaceSymbol(identity:String, revision:Int):Null<WorkspaceSymbol> {
		for (state in compiler.modules)
			if (state.revision == revision)
				for (symbol in indexedWorkspaceSymbols(state))
					if (symbol.identity == identity)
						return symbol;
		return null;
	}

	public function inlayHints(path:String, start:Int, end:Int, ?token:CancellationToken):Array<InlayHint> {
		var state = stateFor(path), model = state == null ? null : effectiveSemanticModel(state), tokens = state == null ? null : effectiveTokens(state),
			result:Array<InlayHint> = [];
		if (state == null || model == null || tokens == null)
			return result;
		for (index in 0...tokens.length) {
			if (token != null)
				token.check();
			var current = tokens[index];
			if (current.span.start > end)
				break;
			if (current.kind == Var && index + 1 < tokens.length && tokens[index + 1].kind == Identifier) {
				var name = tokens[index + 1], after = index + 2 < tokens.length ? tokens[index + 2] : null;
				if (name.span.end >= start && name.span.end <= end && (after == null || after.kind != Colon)) {
					var context = model.index.completionContext(name.span.end), localType:Null<CompilerType> = null;
					for (local in context.locals)
						if (local.name == name.text)
							localType = local.type;
					if (localType != null)
						result.push({position: name.span.end, label: ": " + compilerTypeName(localType), kind: "type", paddingLeft: false, paddingRight: false});
				}
			}
			if (current.kind == LeftParen && index > 0 && (tokens[index - 1].kind == Identifier || tokens[index - 1].kind == New))
				addParameterHints(path, tokens, index, start, end, result);
		}
		result.sort(function(left, right) return Reflect.compare(left.position, right.position));
		return result;
	}

	public function prepareCallHierarchy(path:String, position:Int):Null<CallHierarchyItem> {
		var context = semanticQuery(path, position);
		if (context == null || context.symbol == null)
			return null;
		return callHierarchyItem(context.symbol);
	}

	public function incomingCalls(identity:String, revision:Int, ?token:CancellationToken):Array<CallHierarchyRelation>
		return hierarchyCalls(identity, revision, true, token);

	public function outgoingCalls(identity:String, revision:Int, ?token:CancellationToken):Array<CallHierarchyRelation>
		return hierarchyCalls(identity, revision, false, token);

	public function isCallHierarchyCurrent(identity:String, revision:Int):Bool {
		var item = callHierarchyItem(cast identity);
		return item != null && item.revision == revision;
	}

	public function foldingRanges(path:String):Array<FoldingRegion> {
		var state = stateFor(path);
		return state == null ? [] : indexedStructure(state).folds.copy();
	}

	public function selectionRanges(path:String, positions:Array<Int>):Array<Array<SourceSpan>> {
		var state = stateFor(path), result:Array<Array<SourceSpan>> = [];
		if (state == null)
			return result;
		var structure = indexedStructure(state), tokens = effectiveTokens(state);
		for (position in positions) {
			var spans:Array<SourceSpan> = [];
			if (tokens != null)
				for (token in tokens)
					if (token.kind != Eof && position >= token.span.start && position <= token.span.end) {
						spans.push(token.span);
						break;
					}
			for (span in structure.containers)
				if (position >= span.start && position <= span.end)
					spans.push(span);
			spans.sort(function(left, right) return Reflect.compare(left.end - left.start, right.end - right.start));
			var unique:Array<SourceSpan> = [];
			for (span in spans)
				if (unique.length == 0 || unique[unique.length - 1].start != span.start || unique[unique.length - 1].end != span.end)
					unique.push(span);
			result.push(unique);
		}
		return result;
	}

	public function documentLinks(path:String, ?token:CancellationToken):Array<DocumentLink> {
		var state = stateFor(path), tokens = state == null ? null : effectiveTokens(state), result:Array<DocumentLink> = [];
		if (state == null || tokens == null)
			return result;
		var index = 0;
		while (index < tokens.length) {
			if (token != null)
				token.check();
			if (tokens[index].kind != Import) {
				index++;
				continue;
			}
			index++;
			if (index >= tokens.length || tokens[index].kind != Identifier)
				continue;
			var start = tokens[index].span.start, end = tokens[index].span.end, parts = [tokens[index].text];
			index++;
			while (index + 1 < tokens.length && tokens[index].kind == Dot && tokens[index + 1].kind == Identifier) {
				parts.push(tokens[index + 1].text);
				end = tokens[index + 1].span.end;
				index += 2;
			}
			var importPath = parts.join("."), target = importedModule(importPath);
			if (target != null)
				result.push({span: state.source.span(start, end), targetPath: target.source.path, tooltip: "Open " + importPath});
		}
		return result;
	}

	function workspaceSymbolIdentity(identity:String):Null<WorkspaceSymbol> {
		for (state in compiler.modules)
			for (symbol in indexedWorkspaceSymbols(state))
				if (symbol.identity == identity)
					return symbol;
		return null;
	}

	function importedModule(importPath:String):Null<ModuleState> {
		var candidate = importPath;
		while (candidate.length > 0) {
			var state = compiler.modules.get(candidate);
			if (state != null)
				return state;
			var separator = candidate.lastIndexOf(".");
			if (separator < 0)
				break;
			candidate = candidate.substring(0, separator);
		}
		return null;
	}

	function callHierarchyItem(identity:SemanticSymbolId):Null<CallHierarchyItem> {
		var resolved = compiler.semanticWorkspace.indexedSymbol(identity);
		if (resolved == null)
			return null;
		var signature = compiler.semanticWorkspace.indexedSignature(identity), kind = switch resolved.symbol.kind {
			case DeclarationKind.Function: "function";
			case DeclarationKind.Class: "class";
			case DeclarationKind.Member if (signature != null): "method";
			default: return null;
		}, documentation = documentationFor(resolved.state, resolved.symbol.declaration), detail = signature == null ? resolved.symbol.name : signature.label;
		if (documentation.markdown.length > 0)
			detail += " — " + documentation.markdown.split("\n")[0];
		return {
			identity: Std.string(identity),
			name: sourceName(resolved.symbol.name),
			kind: kind,
			detail: detail,
			path: resolved.state.source.path,
			span: resolved.symbol.declaration,
			revision: resolved.state.revision,
			documentation: documentation.markdown
		};
	}

	function hierarchyCalls(identity:String, revision:Int, incoming:Bool, ?token:CancellationToken):Array<CallHierarchyRelation> {
		var origin = callHierarchyItem(cast identity), grouped:Map<String, CallHierarchyRelation> = [];
		if (origin == null || origin.revision != revision)
			return [];
		for (located in compiler.semanticWorkspace.indexedCalls(token)) {
			var edge = located.edge, matches = incoming ? Std.string(edge.callee) == identity : Std.string(edge.caller) == identity;
			if (!matches)
				continue;
			var relatedId = incoming ? edge.caller : edge.callee, key = Std.string(relatedId), relation = grouped.get(key);
			if (relation == null) {
				var item = callHierarchyItem(relatedId);
				if (item == null)
					continue;
				grouped.set(key, relation = {item: item, ranges: []});
			}
			relation.ranges.push(edge.span);
		}
		var result = [for (relation in grouped) relation];
		result.sort(function(left, right) return Reflect.compare(left.item.identity, right.item.identity));
		for (relation in result)
			relation.ranges.sort(function(left, right) return Reflect.compare(left.start, right.start));
		return result;
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

	public function complete(path:String, position:Int, ?token:CancellationToken):Array<CompletionItem>
		return completeResult(path, position, token).items;

	public function completeResult(path:String, position:Int, ?token:CancellationToken):CompletionResult {
		if (token != null)
			token.check();
		var state = stateFor(path),
			result:Array<CompletionItem> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return completionResult(result);
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
				return completionResult(result);
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
						signature == null ? null : symbol.name + "(", Std.string(symbol.id));
				}
		if (qualifier == null)
			for (candidate in compiler.semanticWorkspace.importableSymbols(state, token)) {
				var symbol = candidate.symbol, signature = compiler.semanticWorkspace.indexedSignature(symbol.id);
				addMember(symbol.name, completionDeclarationKind(symbol.kind), symbol.name, prefix, result, 4,
					signature == null ? null : symbol.name + "(", Std.string(symbol.id), candidate.importPath);
			}
		if (qualifier == null) {
			var candidates = workspaceSymbols(prefix, token), counts:Map<String, Int> = [];
			for (candidate in candidates)
				if (candidate.container == null && isImportableCompletionKind(candidate.kind))
					counts.set(candidate.name, (counts.exists(candidate.name) ? counts.get(candidate.name) : 0) + 1);
			for (candidate in candidates) {
				var module = ModulePath.fromFile(candidate.path);
				if (candidate.container == null && isImportableCompletionKind(candidate.kind) && counts.get(candidate.name) == 1 && module != state.name)
					addMember(candidate.name, candidate.kind, candidate.detail, prefix, result, 4, null, "workspace|" + candidate.identity, module);
			}
		}
		for (symbol in documentSymbols(path))
			addMember(symbol.name, symbol.kind, symbol.detail, prefix, result);
		sortCompletion(result);
		tagResults(result, state);
		return completionResult(result);
	}

	public function resolveCompletion(path:String, identity:String, revision:Int, ?importPath:String):Null<ResolvedCompletion> {
		var state = stateFor(path);
		if (state == null || state.revision != revision)
			return null;
		if (StringTools.startsWith(identity, "workspace|")) {
			var candidate = workspaceSymbolIdentity(identity.substring("workspace|".length));
			if (candidate == null)
				return null;
			var edits:Array<TextEdit> = [], edit = importPath == null ? null : importEdit(state, importPath);
			if (edit != null)
				edits.push(edit);
			return {
				detail: candidate.detail,
				documentation: candidate.documentation == null || candidate.documentation.length == 0 ? "Declared in " + candidate.path : candidate.documentation,
				edits: edits
			};
		}
		var resolved = compiler.semanticWorkspace.indexedSymbol(cast identity);
		if (resolved == null)
			return null;
		var signature = compiler.semanticWorkspace.indexedSignature(cast identity), edits:Array<TextEdit> = [];
		if (importPath != null) {
			var edit = importEdit(state, importPath);
			if (edit != null)
				edits.push(edit);
		}
		var documentation = documentationFor(resolved.state, resolved.symbol.declaration);
		return {
			detail: signature == null ? resolved.symbol.name + ":" + Std.string(resolved.symbol.kind) : signature.label,
			documentation: documentation.markdown.length == 0 ? "Declared in " + resolved.state.source.path : documentation.markdown,
			edits: edits
		};
	}

	public function documentHighlights(path:String, position:Int, ?token:CancellationToken):Array<DocumentHighlight> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position), result:Array<DocumentHighlight> = [];
		if (context == null || context.symbol == null)
			return result;
		var declaration = context.model.index.symbol(context.symbol),
			source = context.state.source.text;
		for (span in context.model.index.locations(context.symbol)) {
			if (token != null)
				token.check();
			result.push({
				span: span,
				write: declaration != null && sameSpan(span, declaration.declaration) || assignmentFollows(source, span.end)
			});
		}
		result.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		return result;
	}

	public function semanticTokens(path:String, ?token:CancellationToken):Array<SemanticToken> {
		var state = stateFor(path), result:Array<SemanticToken> = [],
			tokens = state == null ? null : effectiveTokens(state),
			model = state == null ? null : effectiveSemanticModel(state);
		if (state == null || tokens == null)
			return result;
		for (index in 0...tokens.length) {
			var lexical = tokens[index];
			if (token != null)
				token.check();
			if (lexical.kind == Eof)
				continue;
			var type:Null<String> = switch lexical.kind {
				case Identifier:
					var semantic = semanticTokenType(model, lexical.span.start);
					semantic == "variable" && isParameterToken(tokens, index) ? "parameter" : semantic;
				case TypeInt, TypeBool, TypeFloat, TypeString, Void: "type";
				case Integer, Float: "number";
				case StringLiteral: "string";
				case LeftParen, RightParen, LeftBrace, RightBrace, Colon, Semicolon, Comma, Dot, Assign, PlusAssign, MinusAssign, Increment,
					Decrement, Plus, Minus, Arrow, Star, Slash, Percent, Less, Greater, LessEqual, GreaterEqual, EqualEqual, NotEqual, Not, AndAnd,
					OrOr, Ampersand, Pipe, Caret, LeftBracket, RightBracket, Question, At: "operator";
				default: "keyword";
			};
			if (type != null) {
				var indexed = model == null ? null : model.index.symbolAt(lexical.span.start), modifiers = [];
				if (indexed != null && semanticDeclaration(model, indexed.id, lexical.span)) {
					modifiers.push("declaration");
					if (documentationFor(state, indexed.declaration).deprecated)
						modifiers.push("deprecated");
					if (hasDeclarationModifier(tokens, index, Static))
						modifiers.push("static");
					if (hasDeclarationModifier(tokens, index, Final))
						modifiers.push("readonly");
				}
				addSemanticSpan(state.source, lexical.span.start, lexical.span.end, type, modifiers, result);
			}
		}
		addCommentTokens(state.source, result);
		result.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		return result;
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

	public function hoverDocumentation(path:String, position:Int):Null<SymbolDocumentation> {
		var context = semanticQuery(path, position);
		if (context == null || context.symbol == null)
			return null;
		var resolved = compiler.semanticWorkspace.indexedSymbol(context.symbol);
		return resolved == null ? null : documentationFor(resolved.state, resolved.symbol.declaration);
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
		var resolved = compiler.semanticWorkspace.indexedSymbol(id), documentation = resolved == null ? null : documentationFor(resolved.state, resolved.symbol.declaration);
		if (documentation != null) {
			Reflect.setField(result, "documentation", documentation.markdown);
			Reflect.setField(result, "parameterDocumentation", [for (parameter in signature.parameters) {
				var separator = parameter.indexOf(":"), name = separator < 0 ? parameter : parameter.substring(0, separator);
				documentation.parameters.get(name);
			}]);
		}
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

	public function typeDefinition(path:String, position:Int, ?token:CancellationToken):Null<SymbolLocation> {
		if (token != null)
			token.check();
		var context = semanticQuery(path, position);
		if (context == null)
			return null;
		var target:Null<SemanticSymbolId> = null, symbol = context.symbol == null ? null : compiler.semanticWorkspace.indexedSymbol(context.symbol);
		if (symbol != null && isTypeDeclaration(symbol.symbol.kind))
			target = symbol.symbol.id;
		else {
			var declaration = typeDeclaration(context.model.index.typeAt(position));
			if (declaration != null)
				target = compiler.semanticWorkspace.resolveTypeSymbolId(declaration);
		}
		if (target == null)
			return null;
		var resolved = compiler.semanticWorkspace.indexedSymbol(target);
		return resolved == null ? null : {
			path: resolved.symbol.declaration.file.path,
			span: resolved.symbol.declaration,
			revision: snapshotRevision(resolved.state),
			stale: snapshotRevision(resolved.state) != resolved.state.revision
		};
	}

	public function implementations(path:String, position:Int, ?token:CancellationToken):Array<SymbolLocation> {
		var context = semanticQuery(path, position);
		if (context == null || context.symbol == null)
			return [];
		return [
			for (implementation in compiler.semanticWorkspace.implementations(context.symbol, token))
				{
					path: implementation.span.file.path,
					span: implementation.span,
					revision: snapshotRevision(implementation.state),
					stale: snapshotRevision(implementation.state) != implementation.state.revision
				}
		];
	}

	static function typeDeclaration(type:Null<CompilerType>):Null<String>
		return switch type {
			case TNullable(element): typeDeclaration(element);
			case TAbstract(declaration, _, _), TInstance(_, declaration, _): cast declaration;
			default: null;
		};

	static function isTypeDeclaration(kind:DeclarationKind):Bool
		return kind == DeclarationKind.Alias || kind == DeclarationKind.Enum || kind == DeclarationKind.Abstract || kind == DeclarationKind.Interface
			|| kind == DeclarationKind.Class;

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

	static function isImportableCompletionKind(kind:String):Bool
		return kind == "type" || kind == "class" || kind == "interface" || kind == "enum" || kind == "function";

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

	static function addMember(label:String, kind:String, detail:String, prefix:String, result:Array<CompletionItem>, ?rank:Int = 3, ?insertText:String,
			?identity:String, ?importPath:String):Void {
		if ((prefix.length == 0 || StringTools.startsWith(label, prefix)) && [for (item in result) item.label].indexOf(label) < 0)
			result.push({
				label: label,
				kind: kind,
				detail: detail,
				sortText: Std.string(rank) + "_" + label,
				insertText: insertText,
				identity: identity,
				importPath: importPath
			});
	}

	function importEdit(state:ModuleState, importPath:String):Null<TextEdit> {
		var ast = effectiveAst(state), tokens = effectiveTokens(state);
		if (ast == null || tokens == null || ast.imports.indexOf(importPath) >= 0)
			return null;
		var separator = importPath.lastIndexOf("."), targetPackage = separator < 0 ? "" : importPath.substring(0, separator),
			currentPackage = ast.packageName == null ? "" : Std.string(ast.packageName);
		if (targetPackage == currentPackage)
			return null;
		var insertion = 0;
		for (index in 0...tokens.length)
			if (tokens[index].kind == Semicolon && index > 0 && (tokens[index - 1].kind == Identifier || tokens[index - 1].kind == Package)) {
				var cursor = index - 1;
				while (cursor >= 0 && (tokens[cursor].kind == Identifier || tokens[cursor].kind == Dot))
					cursor--;
				if (cursor >= 0 && (tokens[cursor].kind == Import || tokens[cursor].kind == Package))
					insertion = tokens[index].span.end;
			}
		var replacement = insertion == 0 ? 'import $importPath;\n' : '\nimport $importPath;';
		return {path: state.source.path, span: state.source.span(insertion, insertion), replacement: replacement, revision: state.revision, stale: false};
	}

	static function sortCompletion(result:Array<CompletionItem>):Void
		result.sort(function(left, right) return Reflect.compare(left.sortText, right.sortText));

	static function completionResult(result:Array<CompletionItem>):CompletionResult {
		var incomplete = result.length > MAX_COMPLETION_ITEMS;
		return {items: incomplete ? result.slice(0, MAX_COMPLETION_ITEMS) : result, isIncomplete: incomplete};
	}

	static function sameSpan(left:SourceSpan, right:SourceSpan):Bool
		return left.file.path == right.file.path && left.start == right.start && left.end == right.end;

	static function assignmentFollows(source:String, position:Int):Bool {
		while (position < source.length) {
			var code = source.charCodeAt(position);
			if (code != 32 && code != 9 && code != 10 && code != 13)
				break;
			position++;
		}
		if (position >= source.length)
			return false;
		var current = source.charAt(position), next = source.charAt(position + 1);
		if (current == "=")
			return next != "=" && next != ">";
		return (current == "+" || current == "-" || current == "*" || current == "/" || current == "%" || current == "&" || current == "|"
			|| current == "^") && next == "=";
	}

	static function semanticTokenType(model:Null<SemanticModel>, position:Int):String {
		var symbol = model == null ? null : model.index.symbolAt(position);
		if (symbol == null)
			return "variable";
		return switch symbol.kind {
			case DeclarationKind.Alias, DeclarationKind.Abstract: "type";
			case DeclarationKind.Class: "class";
			case DeclarationKind.Interface: "interface";
			case DeclarationKind.Enum: "enum";
			case DeclarationKind.EnumCase: "enumMember";
			case DeclarationKind.TypeParameter: "typeParameter";
			case DeclarationKind.Function: "function";
			case DeclarationKind.Member:
				model.index.signature(symbol.id) != null ? "method" : Std.string(symbol.id).indexOf(":local:") >= 0 ? "variable" : "property";
		};
	}

	static function isParameterToken(tokens:Array<compiler.syntax.Token>, index:Int):Bool {
		if (index + 1 >= tokens.length || tokens[index + 1].kind != Colon)
			return false;
		var depth = 0, cursor = index - 1;
		while (cursor >= 0) {
			switch tokens[cursor].kind {
				case RightParen: depth++;
				case LeftParen:
					if (depth == 0)
						return cursor > 0 && (tokens[cursor - 1].kind == Identifier || tokens[cursor - 1].kind == New);
					depth--;
				case LeftBrace, RightBrace, Semicolon: return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	static function hasDeclarationModifier(tokens:Array<compiler.syntax.Token>, index:Int, modifier:TokenKind):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			var kind = tokens[cursor].kind;
			if (kind == modifier)
				return true;
			if (kind == LeftBrace || kind == RightBrace || kind == Semicolon)
				return false;
			cursor--;
		}
		return false;
	}

	static function semanticDeclaration(model:SemanticModel, id:SemanticSymbolId, span:SourceSpan):Bool {
		var locations = model.index.locations(id);
		return locations.length > 0 && sameSpan(locations[0], span);
	}

	static function addCommentTokens(file:compiler.Source.SourceFile, result:Array<SemanticToken>):Void {
		var source = file.text, position = 0;
		while (position + 1 < source.length) {
			var quote = source.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < source.length) {
					if (source.charAt(position) == "\\")
						position += 2;
					else if (source.charAt(position++) == quote)
						break;
				}
				continue;
			}
			if (source.charAt(position) != "/") {
				position++;
				continue;
			}
			var next = source.charAt(position + 1), start = position;
			if (next == "/") {
				position += 2;
				while (position < source.length && source.charCodeAt(position) != 10)
					position++;
				addSemanticSpan(file, start, position, "comment", [], result);
			} else if (next == "*") {
				position += 2;
				while (position + 1 < source.length && !(source.charAt(position) == "*" && source.charAt(position + 1) == "/"))
					position++;
				position = Std.int(Math.min(source.length, position + 2));
				addSemanticSpan(file, start, position, "comment", [], result);
			} else
				position++;
		}
	}

	static function addSemanticSpan(file:compiler.Source.SourceFile, start:Int, end:Int, type:String, modifiers:Array<String>,
			result:Array<SemanticToken>):Void {
		var partStart = start, position = start;
		while (position < end) {
			if (file.text.charCodeAt(position) == 10) {
				if (position > partStart)
					result.push({span: file.span(partStart, position), type: type, modifiers: modifiers.copy()});
				partStart = position + 1;
			}
			position++;
		}
		if (end > partStart)
			result.push({span: file.span(partStart, end), type: type, modifiers: modifiers.copy()});
	}

	static function completionTypeCompatible(actual:CompilerType, expected:CompilerType):Bool {
		if (TypeRelations.equals(actual, expected))
			return true;
		return switch expected {
			case TDynamic: true;
			case TNullable(element): completionTypeCompatible(actual, element);
			default: false;
		};
	}

	function addParameterHints(path:String, tokens:Array<compiler.syntax.Token>, open:Int, start:Int, end:Int, result:Array<InlayHint>):Void {
		var signature = signatureHelp(path, tokens[open].span.end);
		if (signature == null || signature.parameters.length == 0)
			return;
		var depth = 1, argument = 0, cursor = open + 1, argumentStart = cursor;
		while (cursor < tokens.length && depth > 0) {
			var kind = tokens[cursor].kind;
			switch kind {
				case LeftParen, LeftBracket, LeftBrace: depth++;
				case RightParen, RightBracket, RightBrace:
					depth--;
					if (depth == 0) {
						addParameterHint(tokens, argumentStart, cursor, argument, signature.parameters, start, end, result);
						break;
					}
				case Comma:
					if (depth == 1) {
						addParameterHint(tokens, argumentStart, cursor, argument++, signature.parameters, start, end, result);
						argumentStart = cursor + 1;
					}
				default:
			}
			cursor++;
		}
	}

	static function addParameterHint(tokens:Array<compiler.syntax.Token>, startIndex:Int, endIndex:Int, argument:Int, parameters:Array<String>, rangeStart:Int,
			rangeEnd:Int, result:Array<InlayHint>):Void {
		if (argument >= parameters.length || startIndex >= endIndex)
			return;
		var first = tokens[startIndex], parameter = parameters[argument], separator = parameter.indexOf(":"),
			name = separator < 0 ? parameter : parameter.substring(0, separator);
		if (first.span.start < rangeStart || first.span.start > rangeEnd || first.kind == Identifier && first.text == name)
			return;
		result.push({position: first.span.start, label: name + ":", kind: "parameter", paddingLeft: false, paddingRight: true});
	}

	function indexedWorkspaceSymbols(state:ModuleState):Array<WorkspaceSymbol> {
		var cached = workspaceIndex.get(state.name);
		if (cached != null && cached.revision == state.revision)
			return cached.symbols;
		var ast = effectiveAst(state);
		if (ast == null)
			try {
				var conditional = ConditionalCompilation.process(state.source, editorDefines);
				ast = new Parser(new Lexer(state.source, conditional.text).tokenize()).parseProgram();
			} catch (_:CompileError) {}
		var result:Array<WorkspaceSymbol> = [];
		if (ast != null) {
			for (fn in ast.functions)
				addWorkspaceSymbol(result, state, fn.name, "function", null, '${fn.name}():${typeName(fn.result)}', fn.span);
			for (alias in ast.aliases)
				addWorkspaceSymbol(result, state, alias.name, "type", null, 'typedef ${alias.name}=${typeName(alias.type)}', alias.span);
			for (decl in ast.interfaces) {
				addWorkspaceSymbol(result, state, decl.name, "interface", null, 'interface ${decl.name}', decl.span);
				for (method in decl.methods)
					addWorkspaceSymbol(result, state, method.name, "method", decl.name, '${method.name}():${typeName(method.result)}', method.span);
			}
			for (decl in ast.enums) {
				addWorkspaceSymbol(result, state, decl.name, "enum", null, 'enum ${decl.name}', decl.span);
				for (item in decl.cases)
					addWorkspaceSymbol(result, state, item.name, "enumCase", decl.name, decl.name + "." + item.name, item.span);
			}
			for (decl in ast.classes) {
				addWorkspaceSymbol(result, state, decl.name, "class", null, 'class ${decl.name}', decl.span);
				for (field in decl.fields)
					addWorkspaceSymbol(result, state, field.name, "field", decl.name, '${field.name}:${typeName(field.type)}', field.span);
				for (method in decl.methods)
					addWorkspaceSymbol(result, state, method.name, "method", decl.name, '${method.name}():${typeName(method.result)}', method.span);
			}
		}
		workspaceIndex.set(state.name, {revision: state.revision, symbols: result});
		return result;
	}

	function documentationFor(state:ModuleState, span:SourceSpan):SymbolDocumentation {
		var cached = documentationIndex.get(state.name);
		if (cached == null || cached.revision != state.revision) {
			cached = {revision: state.revision, comments: scanDocumentation(state.source.text)};
			documentationIndex.set(state.name, cached);
		}
		var found:Null<SymbolDocumentation> = null;
		for (comment in cached.comments)
			if (comment.end <= span.start && documentationGap(state.source.text.substring(comment.end, span.start)))
				found = comment.documentation;
			else
				break;
		return found == null ? {markdown: "", parameters: [], deprecated: false} : found;
	}

	function indexedStructure(state:ModuleState):StructuralIndexEntry {
		var cached = structuralIndex.get(state.name);
		if (cached != null && cached.revision == state.revision)
			return cached;
		var folds:Array<FoldingRegion> = [], containers:Array<SourceSpan> = [], tokens = effectiveTokens(state), source = state.source;
		if (tokens != null) {
			var braces:Array<compiler.syntax.Token> = [], firstImport:Null<Int> = null, lastImport:Null<Int> = null, inImport = false;
			for (token in tokens)
				switch token.kind {
					case LeftBrace: braces.push(token);
					case RightBrace:
						if (braces.length > 0) {
							var open = braces.pop(), span = source.span(open.span.start, token.span.end);
							folds.push({span: span, kind: "region"});
							containers.push(span);
						}
					case Import:
						inImport = true;
						if (firstImport == null)
							firstImport = token.span.start;
					case Semicolon:
						if (inImport) {
							lastImport = token.span.end;
							inImport = false;
						}
					default:
				}
			if (firstImport != null && lastImport != null)
				folds.push({span: source.span(firstImport, lastImport), kind: "imports"});
		}
		for (span in commentSpans(source.text, source)) {
			folds.push({span: span, kind: "comment"});
			containers.push(span);
		}
		addConditionalFolds(source, folds, containers);
		for (symbol in indexedWorkspaceSymbols(state))
			containers.push(symbol.span);
		containers.push(source.span(0, source.text.length));
		folds.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
		structuralIndex.set(state.name, cached = {revision: state.revision, folds: folds, containers: containers});
		return cached;
	}

	static function commentSpans(text:String, file:compiler.Source.SourceFile):Array<SourceSpan> {
		var result:Array<SourceSpan> = [], position = 0;
		while (position + 1 < text.length) {
			var quote = text.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < text.length)
					if (text.charAt(position) == "\\") position += 2; else if (text.charAt(position++) == quote) break;
				continue;
			}
			var marker = text.substr(position, 2), start = position;
			if (marker == "//") {
				var newline = text.indexOf("\n", position + 2);
				position = newline < 0 ? text.length : newline;
				result.push(file.span(start, position));
			} else if (marker == "/*") {
				var close = text.indexOf("*/", position + 2);
				position = close < 0 ? text.length : close + 2;
				result.push(file.span(start, position));
			} else
				position++;
		}
		return result;
	}

	static function addConditionalFolds(file:compiler.Source.SourceFile, folds:Array<FoldingRegion>, containers:Array<SourceSpan>):Void {
		var source = file.text, offset = 0, stack:Array<Int> = [];
		while (offset < source.length) {
			var newline = source.indexOf("\n", offset), end = newline < 0 ? source.length : newline + 1,
				line = StringTools.trim(source.substring(offset, end));
			if (StringTools.startsWith(line, "#if"))
				stack.push(offset);
			else if (StringTools.startsWith(line, "#end") && stack.length > 0) {
				var span = file.span(stack.pop(), end);
				folds.push({span: span, kind: "region"});
				containers.push(span);
			}
			offset = end;
		}
	}

	static function scanDocumentation(source:String):Array<{end:Int, documentation:SymbolDocumentation}> {
		var result = [], position = 0;
		while (position + 2 < source.length) {
			var quote = source.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < source.length)
					if (source.charAt(position) == "\\")
						position += 2;
					else if (source.charAt(position++) == quote)
						break;
				continue;
			}
			if (source.substr(position, 2) == "//") {
				var newline = source.indexOf("\n", position + 2);
				position = newline < 0 ? source.length : newline + 1;
				continue;
			}
			if (source.substr(position, 3) != "/**") {
				position++;
				continue;
			}
			var close = source.indexOf("*/", position + 3);
			if (close < 0)
				break;
			result.push({end: close + 2, documentation: normalizeDocumentation(source.substring(position + 3, close))});
			position = close + 2;
		}
		return result;
	}

	static function documentationGap(gap:String):Bool {
		var trimmed = StringTools.trim(gap);
		if (trimmed.length == 0)
			return true;
		// Metadata may legally sit between a doc comment and its declaration.
		return StringTools.startsWith(trimmed, "@:") && trimmed.indexOf(";") < 0 && trimmed.indexOf("{") < 0 && trimmed.indexOf("}") < 0;
	}

	static function normalizeDocumentation(raw:String):SymbolDocumentation {
		var body:Array<String> = [], parameters:Map<String, String> = [], deprecated = false;
		for (line in raw.split("\n")) {
			var value = StringTools.trim(line);
			if (StringTools.startsWith(value, "*"))
				value = StringTools.trim(value.substring(1));
			if (StringTools.startsWith(value, "@param ")) {
				var content = StringTools.trim(value.substring(7)), separator = content.indexOf(" ");
				parameters.set(separator < 0 ? content : content.substring(0, separator), separator < 0 ? "" : StringTools.trim(content.substring(separator + 1)));
			} else if (StringTools.startsWith(value, "@return "))
				body.push("**Returns:** " + StringTools.trim(value.substring(8)));
			else if (StringTools.startsWith(value, "@deprecated")) {
				deprecated = true;
				var message = StringTools.trim(value.substring(11));
				body.push("**Deprecated.**" + (message.length == 0 ? "" : " " + message));
			} else if (StringTools.startsWith(value, "@see "))
				body.push("**See:** " + StringTools.trim(value.substring(5)));
			else
				body.push(value);
		}
		while (body.length > 0 && body[0].length == 0)
			body.shift();
		while (body.length > 0 && body[body.length - 1].length == 0)
			body.pop();
		return {markdown: body.join("\n"), parameters: parameters, deprecated: deprecated};
	}

	function addWorkspaceSymbol(result:Array<WorkspaceSymbol>, state:ModuleState, name:String, kind:String, container:Null<String>, detail:String,
			span:SourceSpan):Void {
		var documentation = documentationFor(state, span);
		result.push({
			identity: state.name + ":" + kind + ":" + (container == null ? "" : container + ".") + name,
			name: name,
			kind: kind,
			container: container,
			detail: detail,
			path: state.source.path,
			span: span,
			revision: state.revision,
			documentation: documentation.markdown,
			deprecated: documentation.deprecated
		});
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
