package editor;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.service.CancellationError;
import compiler.service.CancellationToken;
import compiler.service.LanguageService;
import editor.lsp.DocumentStore;
import editor.lsp.DocumentStore.LspDocument;
import editor.lsp.ProjectWorkspace;
import haxe.Json;

private class LspRequestError {
	public final code:Int;
	public final message:String;

	public function new(code:Int, message:String) {
		this.code = code;
		this.message = message;
	}
}

/** Minimal standard LSP adapter over the compiler-owned language service. */
class LspProtocol {
	static final SEMANTIC_TOKEN_TYPES = ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
		"property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
		"decorator"];
	static final SEMANTIC_TOKEN_MODIFIERS = ["declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification",
		"documentation", "defaultLibrary"];
	final service:LanguageService;
	final documents = new DocumentStore();
	final profiler = new ProfilerService();

	public final project = new ProjectWorkspace();

	final publishedDiagnostics:Map<String, String> = [];
	final activeRequests:Map<String, CancellationToken> = [];
	final requestMutex = new sys.thread.Mutex();
	final diagnosticMutex = new sys.thread.Mutex();
	final pendingDiagnosticTargets:Map<String, Bool> = [];
	var diagnosticToken:Null<CancellationToken>;
	var deferDiagnostics = false;
	var analysisGeneration = 0;
	var completionSnippets = false;

	public var lastForegroundAnalysisMs(default, null):Float = 0.0;
	public var lastBackgroundAnalysisMs(default, null):Float = 0.0;

	var shutdownRequested = false;
	var exitRequested = false;

	public function new(?service:LanguageService)
		this.service = service == null ? new LanguageService() : service;

	/** Handle one JSON-RPC message and return zero or more JSON-RPC messages. */
	public function handle(message:String):Array<String> {
		var request:Dynamic;
		try {
			request = Json.parse(message);
		} catch (_:Dynamic) {
			return [error(null, -32700, "Parse error")];
		}
		var method:String = Reflect.field(request, "method"),
			id:Dynamic = Reflect.field(request, "id");
		if (method == null)
			return id != null
				&& (Reflect.hasField(request, "result") || Reflect.hasField(request, "error")) ? [] : id == null ? [] : [error(id, -32600, "Invalid Request")];
		if (shutdownRequested && method != "exit")
			return id == null ? [] : [error(id, -32600, "Server has shut down")];
		try {
			return switch method {
				case "initialize": initialize(request, id);
				case "initialized": [watcherRegistration()];
				case "shutdown":
					shutdownRequested = true;
					profiler.close();
					[response(id, null)];
				case "exit":
					exitRequested = true;
					profiler.close();
					[];
				case "workspace/executeCommand": [response(id, executeCommand(request))];
				case "textDocument/didOpen": synchronize(request, true);
				case "textDocument/didChange": synchronize(request, false);
				case "textDocument/didClose": closeDocument(request);
				case "workspace/didChangeWatchedFiles": watchedFiles(request);
				case "workspace/didChangeConfiguration": changeConfiguration(request);
				case "textDocument/documentSymbol": cancellable(id, token -> documentSymbols(request, token));
				case "textDocument/completion": cancellable(id, token -> completion(request, token));
				case "completionItem/resolve": cancellable(id, token -> resolveCompletion(request, token));
				case "textDocument/documentHighlight": cancellable(id, token -> documentHighlights(request, token));
				case "textDocument/semanticTokens/full": cancellable(id, token -> semanticTokens(request, token));
				case "textDocument/codeAction": cancellable(id, token -> codeActions(request, token));
				case "textDocument/hover": cancellable(id, token -> hover(request, token));
				case "textDocument/signatureHelp": cancellable(id, token -> signatureHelp(request, token));
				case "textDocument/definition": cancellable(id, token -> definition(request, token));
				case "textDocument/references": cancellable(id, token -> references(request, token));
				case "textDocument/prepareRename": cancellable(id, token -> prepareRename(request, token));
				case "textDocument/rename": cancellable(id, token -> rename(request, token));
				case "$/cancelRequest":
					cancel(request);
					[];
				default: id == null ? [] : [error(id, -32601, 'Method not found: $method')];
			};
		} catch (failure:LspRequestError) {
			return id == null ? [] : [error(id, failure.code, failure.message)];
		} catch (_:CancellationError) {
			return id == null ? [] : [error(id, -32800, "Request cancelled")];
		} catch (failure:Dynamic) {
			return id == null ? [] : [error(id, -32603, Std.string(failure))];
		}
	}

	public function shouldExit():Bool
		return exitRequested;

	public function enableProfilerNotifications(emit:String->Void):Void
		profiler.setEmitter(message -> emit(notification(Reflect.field(message, "method"), Reflect.field(message, "params"))));

	public function dispose():Void
		profiler.close();

	public function enableDeferredDiagnostics():Void
		deferDiagnostics = true;

	public function cancelPendingDiagnostics():Void {
		diagnosticMutex.acquire();
		if (diagnosticToken != null)
			diagnosticToken.cancel();
		diagnosticMutex.release();
	}

	public function analyzePendingDiagnostics():Array<String> {
		if (!deferDiagnostics)
			return [];
		var generation = analysisGeneration,
			targets = [for (target in pendingDiagnosticTargets.keys()) target],
			token = new CancellationToken();
		for (target in targets)
			pendingDiagnosticTargets.remove(target);
		targets.sort(Reflect.compare);
		diagnosticMutex.acquire();
		diagnosticToken = token;
		diagnosticMutex.release();
		var started = Sys.time();
		try {
			for (target in targets)
				try
					service.analyze(target, token)
				catch (cancelled:CancellationError)
					throw cancelled
				catch (_:CompileError) {} catch (_:Dynamic) {}
		} catch (_:CancellationError) {
			clearDiagnosticToken(token);
			lastBackgroundAnalysisMs = (Sys.time() - started) * 1000.0;
			return [];
		}
		clearDiagnosticToken(token);
		lastBackgroundAnalysisMs = (Sys.time() - started) * 1000.0;
		return generation == analysisGeneration ? diagnosticNotifications(generation) : [];
	}

	function initialize(request:Dynamic, id:Dynamic):Array<String> {
		var params = required(request, "params");
		completionSnippets = clientCompletionSnippets(params);
		project.initialize(params, service);
		if (project.configurations.length > 0)
			configure(project.configurations[0]);
		var result = [response(id, initializeResult())];
		for (message in project.errors)
			result.push(notification("window/showMessage", {type: 1, message: 'Haxe project configuration: $message'}));
		return result;
	}

	function changeConfiguration(request:Dynamic):Array<String> {
		var params = required(request, "params"),
			settings:Dynamic = Reflect.field(params, "settings"),
			selected:Dynamic = settings;
		if (settings != null && Reflect.hasField(settings, "haxeon"))
			selected = Reflect.field(settings, "haxeon");
		var id:Dynamic = selected == null ? null : Reflect.field(selected, "configuration");
		if (id != null && !Std.isOfType(id, String))
			return [
				notification("window/showMessage", {type: 1, message: "haxeon.configuration must be a build id or configuration path"})
			];
		if (!project.selectConfiguration(cast id))
			return [
				notification("window/showMessage", {type: 1, message: 'Unknown Haxe build configuration: $id'})
			];
		var configuration = project.configurationFor("");
		if (configuration != null)
			configure(configuration);
		analysisGeneration++;
		for (module in service.compiler.modules.keys())
			pendingDiagnosticTargets.set(module, true);
		return [];
	}

	function watcherRegistration():String
		return serverRequest("haxeon/register-watchers", "client/registerCapability", {
			registrations: [
				{
					id: "haxeon-workspace-files",
					method: "workspace/didChangeWatchedFiles",
					registerOptions: {
						watchers: [
							{globPattern: "**/*.hx", kind: 7},
							{globPattern: "**/*.hxml", kind: 7},
							{globPattern: "**/haxe.json", kind: 7}
						]
					}
				}
			]
		});

	function initializeResult():Dynamic
		return {
			capabilities: {
				positionEncoding: "utf-16",
				textDocumentSync: {openClose: true, change: 1},
				documentSymbolProvider: true,
				completionProvider: {triggerCharacters: ["."], resolveProvider: true},
				documentHighlightProvider: true,
				semanticTokensProvider: {
					legend: {tokenTypes: SEMANTIC_TOKEN_TYPES, tokenModifiers: SEMANTIC_TOKEN_MODIFIERS},
					full: true
				},
				codeActionProvider: {codeActionKinds: ["quickfix"]},
				hoverProvider: true,
				signatureHelpProvider: {triggerCharacters: ["(", ","]},
				definitionProvider: true,
				referencesProvider: true,
				renameProvider: {prepareProvider: true},
				executeCommandProvider: {
					commands: [
						"haxeon.profiler.connect",
						"haxeon.profiler.start",
						"haxeon.profiler.pause",
						"haxeon.profiler.poll",
						"haxeon.profiler.reset",
						"haxeon.profiler.snapshot",
						"haxeon.profiler.disconnect"
					]
				},
				workspace: {workspaceFolders: {supported: true, changeNotifications: true}}
			},
			serverInfo: {name: "haxeon", version: "0.1.0"}
		};

	function executeCommand(request:Dynamic):Dynamic {
		var params = required(request, "params"), command = requiredString(params, "command"), rawArguments:Dynamic = Reflect.field(params, "arguments"),
			arguments:Array<Dynamic> = rawArguments == null ? [] : cast rawArguments;
		if (!Std.isOfType(arguments, Array))
			throw 'Field "arguments" must be an array';
		if (!StringTools.startsWith(command, "haxeon.profiler."))
			throw new LspRequestError(-32602, 'Unsupported command "$command"');
		return profiler.execute(command, arguments);
	}

	function synchronize(request:Dynamic, opening:Bool):Array<String> {
		var params:Dynamic = required(request, "params"), textDocument:Dynamic = required(params, "textDocument"), uri = requiredString(textDocument, "uri"),
			version = requiredInt(textDocument, "version"), source:String;
		if (opening)
			source = requiredString(textDocument, "text");
		else {
			var changes:Array<Dynamic> = cast required(params, "contentChanges");
			if (changes.length == 0)
				return [];
			if (Reflect.hasField(changes[changes.length - 1], "range"))
				throw "Incremental document changes were not negotiated";
			source = requiredString(changes[changes.length - 1], "text");
		}
		var document = opening ? documents.open(uri, version, source) : documents.replace(uri, version, source);
		if (document == null)
			return [];
		var generation = ++analysisGeneration;
		var path = activateConfiguration(document.path);
		service.update(path, document.source);
		var changedModule = ModulePath.fromFile(path),
			targets = service.compiler.dependentModules(changedModule);
		if (targets.length == 0)
			targets.push(changedModule);
		if (deferDiagnostics) {
			for (target in targets)
				pendingDiagnosticTargets.set(target, true);
			return [];
		}
		for (target in targets)
			try
				service.analyze(target)
			catch (_:CompileError) {}
		return generation == analysisGeneration ? diagnosticNotifications(generation) : [];
	}

	function closeDocument(request:Dynamic):Array<String> {
		var uri = documentUri(request),
			document = documents.get(uri),
			compilerPath = project.compilerPath(document.path),
			module = ModulePath.fromFile(compilerPath),
			targets = service.compiler.dependentModules(module);
		documents.close(uri);
		var restored = project.restore(document.path, service);
		publishedDiagnostics.set(uri, "");
		var result = [notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: []})];
		if (!restored)
			return result;
		var generation = ++analysisGeneration;
		if (targets.length == 0 && service.compiler.modules.exists(module))
			targets.push(module);
		if (deferDiagnostics)
			for (target in targets)
				pendingDiagnosticTargets.set(target, true);
		else {
			for (target in targets)
				try
					service.analyze(target)
				catch (_:Dynamic) {}
			if (generation == analysisGeneration)
				for (message in diagnosticNotifications(generation))
					result.push(message);
		}
		return result;
	}

	function watchedFiles(request:Dynamic):Array<String> {
		var changes:Array<Dynamic> = cast required(required(request, "params"), "changes"),
			targets:Map<String, Bool> = [],
			configurationChanged = false,
			mutated = false;
		for (change in changes) {
			var path = ProjectWorkspace.pathFromUri(requiredString(change, "uri"));
			if (project.isConfiguration(path)) {
				configurationChanged = true;
				continue;
			}
			if (!StringTools.endsWith(path, ".hx"))
				continue;
			var open = documents.forPath(path) != null,
				compilerPath = project.compilerPath(path),
				module = ModulePath.fromFile(compilerPath);
			if (!open) {
				for (dependent in service.compiler.dependentModules(module))
					targets.set(dependent, true);
				mutated = true;
			}
			project.refresh(path, service, open);
			if (!open && service.compiler.modules.exists(module))
				targets.set(module, true);
		}
		if (configurationChanged) {
			project.reload(service, path -> documents.forPath(path) != null);
			for (module in service.compiler.modules.keys())
				targets.set(module, true);
			mutated = true;
		}
		if (!mutated)
			return [];
		var generation = ++analysisGeneration;
		if (deferDiagnostics) {
			for (target in targets.keys())
				pendingDiagnosticTargets.set(target, true);
			return [];
		}
		for (target in targets.keys())
			try
				service.analyze(target)
			catch (_:Dynamic) {}
		return generation == analysisGeneration ? diagnosticNotifications(generation) : [];
	}

	function diagnosticNotifications(generation:Int):Array<String> {
		var pending:Array<{uri:String, fingerprint:String, message:String}> = [],
			states = [for (state in service.compiler.modules) state];
		states.sort(function(left, right) return Reflect.compare(left.source.path, right.source.path));
		for (state in states) {
			if (generation != analysisGeneration)
				return [];
			var diskPath = project.diskPath(state.source.path),
				uri = documents.uri(diskPath),
				fingerprint = diagnosticFingerprint(state.diagnostics);
			if (publishedDiagnostics.get(uri) == fingerprint)
				continue;
			var params:Dynamic = {
				uri: uri,
				diagnostics: [for (diagnostic in state.diagnostics) diagnosticJson(diagnostic)]
			};
			var open = documents.forPath(diskPath);
			if (open != null)
				Reflect.setField(params, "version", open.version);
			pending.push({uri: uri, fingerprint: fingerprint, message: notification("textDocument/publishDiagnostics", params)});
		}
		if (generation != analysisGeneration)
			return [];
		for (publication in pending)
			publishedDiagnostics.set(publication.uri, publication.fingerprint);
		return [for (publication in pending) publication.message];
	}

	static function diagnosticFingerprint(diagnostics:Array<Diagnostic>):String
		return [
			for (diagnostic in diagnostics)
				diagnostic.code
				+ ":"
				+ diagnostic.span.start
				+ ":"
				+ diagnostic.span.end
				+ ":"
				+ diagnostic.message].join("\n");

	function documentSymbols(request:Dynamic, token:CancellationToken):Array<Dynamic> {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		return [
			for (symbol in service.documentSymbols(compilerPath(document)))
				{
					name: symbol.name,
					kind: symbolKind(symbol.kind),
					detail: symbol.detail,
					range: document.range(symbol.span.start, symbol.span.end),
					selectionRange: document.range(symbol.span.start, symbol.span.end)
				}
		];
	}

	function completion(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		var offset = positionOffset(document, position(request)),
			start = identifierStart(document.source, offset),
			completion = service.completeResult(compilerPath(document), offset, token);
		return {
			isIncomplete: completion.isIncomplete,
			items: [
				for (item in completion.items) {
					var insertion = item.insertText == null ? item.label : item.insertText,
						snippet = completionSnippets && StringTools.endsWith(insertion, "("), result:Dynamic = {
						label: item.label,
						kind: completionKind(item.kind),
						detail: item.detail,
						sortText: item.sortText,
						insertTextFormat: snippet ? 2 : 1,
						textEdit: {
							range: document.range(start, offset),
							newText: snippet ? insertion + "${1})" : insertion
						}
					};
					if (item.identity != null)
						Reflect.setField(result, "data", {uri: document.uri, identity: item.identity, revision: item.revision, importPath: item.importPath});
					result;
				}
			]
		};
	}

	function resolveCompletion(request:Dynamic, token:CancellationToken):Dynamic {
		var item:Dynamic = required(request, "params"), data:Dynamic = required(item, "data"), uri = requiredString(data, "uri"),
			document = documents.get(uri), identity = requiredString(data, "identity"), revision = requiredInt(data, "revision"),
			importPath:Dynamic = Reflect.field(data, "importPath");
		if (importPath != null && !Std.isOfType(importPath, String))
			throw new LspRequestError(-32602, "Invalid completion import path");
		token.check();
		var resolved = service.resolveCompletion(compilerPath(document), identity, revision, cast importPath);
		if (resolved == null)
			throw new LspRequestError(-32801, "Completion item no longer matches the current document version");
		Reflect.setField(item, "detail", resolved.detail);
		Reflect.setField(item, "documentation", {kind: "plaintext", value: resolved.documentation});
		Reflect.setField(item, "additionalTextEdits", [
			for (edit in resolved.edits)
				{range: document.range(edit.span.start, edit.span.end), newText: edit.replacement}
		]);
		return item;
	}

	function documentHighlights(request:Dynamic, token:CancellationToken):Array<Dynamic> {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		return [
			for (highlight in service.documentHighlights(compilerPath(document), positionOffset(document, position(request)), token))
				{range: document.range(highlight.span.start, highlight.span.end), kind: highlight.write ? 3 : 2}
		];
	}

	function semanticTokens(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		var data:Array<Int> = [], previousLine = 0, previousCharacter = 0;
		for (semantic in service.semanticTokens(compilerPath(document), token)) {
			var start:Dynamic = document.position(semantic.span.start), end:Dynamic = document.position(semantic.span.end);
			appendSemanticToken(data, start.line, start.character, Std.int(end.character - start.character), semantic.type, semantic.modifiers, previousLine,
				previousCharacter);
			previousLine = start.line;
			previousCharacter = start.character;
		}
		return {data: data};
	}

	function codeActions(request:Dynamic, token:CancellationToken):Array<Dynamic> {
		var document = document(request), params = required(request, "params"), range = required(params, "range"),
			start = positionOffset(document, required(range, "start")), end = positionOffset(document, required(range, "end"));
		token.check();
		return [
			for (action in service.codeActions(compilerPath(document), start, end)) {
				var changes:Map<String, Array<Dynamic>> = [], targets:Map<String, LspDocument> = [];
				for (edit in action.edits) {
					var uri = documents.uri(project.diskPath(edit.path)), target = documentForPath(edit.path), existing = changes.get(uri);
					if (existing == null)
						changes.set(uri, existing = []);
					targets.set(uri, target);
					existing.push({range: target.range(edit.span.start, edit.span.end), newText: edit.replacement});
				}
				{
					title: action.title,
					kind: "quickfix",
					diagnostics: [diagnosticJson(action.diagnostic)],
					isPreferred: true,
					edit: {documentChanges: [
						for (uri => edits in changes)
							{
								textDocument: {uri: uri, version: documents.forPath(targets.get(uri).path) == null ? null : targets.get(uri).version},
								edits: edits
							}
					]}
				}
			}
		];
	}

	function hover(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		var value = service.hover(compilerPath(document), positionOffset(document, position(request)));
		return value == null ? null : {contents: {kind: "plaintext", value: value}};
	}

	function signatureHelp(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		var value = service.signatureHelp(compilerPath(document), positionOffset(document, position(request)));
		return value == null ? null : {
			signatures: [
				{
					label: value.label,
					parameters: [for (parameter in value.parameters) {label: parameter}]
				}
			],
			activeSignature: 0,
			activeParameter: value.activeParameter
		};
	}

	function definition(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		var location = service.definition(compilerPath(document), positionOffset(document, position(request)));
		return location == null ? null : locationJson(location.path, location.span.start, location.span.end);
	}

	function references(request:Dynamic, token:CancellationToken):Array<Dynamic> {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		var locations = service.references(compilerPath(document), positionOffset(document, position(request)), token);
		return [
			for (location in locations)
				locationJson(location.path, location.span.start, location.span.end)
		];
	}

	function ensureAnalyzed(document:LspDocument, token:CancellationToken):Void {
		var path = compilerPath(document);
		if (!deferDiagnostics || service.isCurrent(path))
			return;
		var module = ModulePath.fromFile(path),
			targets = [for (target in pendingDiagnosticTargets.keys()) target],
			started = Sys.time();
		targets.sort(function(left, right) {
			if (left == module)
				return -1;
			if (right == module)
				return 1;
			return Reflect.compare(left, right);
		});
		for (target in targets) {
			token.check();
			pendingDiagnosticTargets.remove(target);
			try
				service.analyze(target, token)
			catch (cancelled:CancellationError)
				throw cancelled
			catch (_:CompileError) {} catch (_:Dynamic) {}
			if (service.isCurrent(path))
				break;
		}
		lastForegroundAnalysisMs = (Sys.time() - started) * 1000.0;
	}

	function cancellable(id:Dynamic, query:CancellationToken->Dynamic):Array<String> {
		var token = new CancellationToken(), key = requestKey(id);
		requestMutex.acquire();
		activeRequests.set(key, token);
		requestMutex.release();
		try {
			var result = query(token);
			removeRequest(key);
			return [response(id, result)];
		} catch (failure:Dynamic) {
			removeRequest(key);
			throw failure;
		}
	}

	function cancel(request:Dynamic):Void {
		var id = Reflect.field(required(request, "params"), "id");
		if (id == null)
			return;
		requestMutex.acquire();
		var token = activeRequests.get(requestKey(id));
		if (token != null)
			token.cancel();
		requestMutex.release();
	}

	function removeRequest(key:String):Void {
		requestMutex.acquire();
		activeRequests.remove(key);
		requestMutex.release();
	}

	function clearDiagnosticToken(token:CancellationToken):Void {
		diagnosticMutex.acquire();
		if (diagnosticToken == token)
			diagnosticToken = null;
		diagnosticMutex.release();
	}

	static function requestKey(id:Dynamic):String
		return Json.stringify(id);

	function prepareRename(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		var offset = positionOffset(document, position(request));
		for (token in service.compiler.modules.get(ModulePath.fromFile(compilerPath(document))).tokens)
			if (offset >= token.span.start && offset <= token.span.end && Std.string(token.kind) == "Identifier")
				return {range: document.range(token.span.start, token.span.end), placeholder: token.text};
		return null;
	}

	function rename(request:Dynamic, token:CancellationToken):Dynamic {
		var document = document(request);
		ensureAnalyzed(document, token);
		requireCurrent(document);
		var params:Dynamic = required(request, "params"),
			edits = service.rename(compilerPath(document), positionOffset(document, position(request)), requiredString(params, "newName")),
			grouped:Map<String, Array<Dynamic>> = [],
			targets:Map<String, LspDocument> = [];
		for (edit in edits) {
			if (edit.stale)
				throw new LspRequestError(-32801, "Rename result is based on stale source");
			var uri = documents.uri(project.diskPath(edit.path)),
				target = documentForPath(edit.path),
				existing = grouped.get(uri);
			if (existing == null)
				grouped.set(uri, existing = []);
			targets.set(uri, target);
			existing.push({range: target.range(edit.span.start, edit.span.end), newText: edit.replacement});
		}
		return {
			documentChanges: [
				for (uri => textEdits in grouped)
					{
						textDocument: {
							uri: uri,
							version: documents.forPath(targets.get(uri).path) == null ? null : targets.get(uri).version
						},
						edits: textEdits
					}
			]
		};
	}

	function locationJson(path:String, start:Int, end:Int):Dynamic {
		var target = documentForPath(path);
		return {uri: documents.uri(project.diskPath(path)), range: target.range(start, end)};
	}

	function documentForPath(path:String):LspDocument {
		var diskPath = project.diskPath(path),
			open = documents.forPath(diskPath);
		if (open != null)
			return open;
		var state = service.compiler.modules.get(ModulePath.fromFile(path));
		if (state == null)
			throw 'Unknown source path: $path';
		return new LspDocument(documents.uri(diskPath), diskPath, state.revision, state.source.text);
	}

	function document(request:Dynamic):LspDocument
		return documents.get(documentUri(request));

	function requireCurrent(document:LspDocument):Void {
		if (!service.isCurrent(compilerPath(document)))
			throw new LspRequestError(-32801, "Semantic snapshot does not match the current document version");
	}

	function compilerPath(document:LspDocument):String
		return activateConfiguration(document.path);

	function activateConfiguration(path:String):String {
		var configuration = project.configurationFor(path);
		if (configuration != null)
			configure(configuration);
		return project.compilerPath(path);
	}

	function configure(configuration:editor.lsp.ProjectWorkspace.HaxeProjectConfiguration):Void
		service.configure(configuration.id, configuration.scopeId, configuration.defines.copy());

	static function documentUri(request:Dynamic):String
		return requiredString(required(required(request, "params"), "textDocument"), "uri");

	static function position(request:Dynamic):Dynamic
		return required(required(request, "params"), "position");

	static function positionOffset(document:LspDocument, position:Dynamic):Int
		return document.offset(requiredInt(position, "line"), requiredInt(position, "character"));

	static function identifierStart(source:String, position:Int):Int {
		while (position > 0) {
			var code = source.charCodeAt(position - 1);
			if (!(code >= 65 && code <= 90 || code >= 97 && code <= 122 || code >= 48 && code <= 57 || code == 95))
				break;
			position--;
		}
		return position;
	}

	static function clientCompletionSnippets(params:Dynamic):Bool {
		var value:Dynamic = Reflect.field(params, "capabilities");
		for (name in ["textDocument", "completion", "completionItem"]) {
			if (value == null)
				return false;
			value = Reflect.field(value, name);
		}
		return value != null && Reflect.field(value, "snippetSupport") == true;
	}

	static function appendSemanticToken(data:Array<Int>, line:Int, character:Int, length:Int, type:String, modifiers:Array<String>, previousLine:Int,
			previousCharacter:Int):Void {
		var modifierBits = 0;
		for (modifier in modifiers) {
			var modifierIndex = SEMANTIC_TOKEN_MODIFIERS.indexOf(modifier);
			if (modifierIndex >= 0)
				modifierBits |= 1 << modifierIndex;
		}
		data.push(line - previousLine);
		data.push(line == previousLine ? character - previousCharacter : character);
		data.push(length);
		data.push(SEMANTIC_TOKEN_TYPES.indexOf(type));
		data.push(modifierBits);
	}

	static function diagnosticJson(diagnostic:Diagnostic):Dynamic
		return {
			range: new LspDocument("", diagnostic.span.file.path, 0, diagnostic.span.file.text).range(diagnostic.span.start, diagnostic.span.end),
			severity: Std.string(diagnostic.severity) == "Warning" ? 2 : 1,
			code: diagnostic.code,
			source: "haxeon",
			message: diagnostic.message
		};

	static function symbolKind(kind:String):Int
		return switch kind {
			case "class": 5;
			case "method": 6;
			case "field": 8;
			case "function": 12;
			case "enum": 10;
			case "interface": 11;
			case "type": 26;
			default: 13;
		};

	static function completionKind(kind:String):Int
		return switch kind {
			case "method": 2;
			case "function": 3;
			case "field": 5;
			case "class": 7;
			case "interface": 8;
			case "enum": 13;
			case "enumCase": 20;
			default: 6;
		};

	static function required(value:Dynamic, name:String):Dynamic {
		var field = Reflect.field(value, name);
		if (field == null)
			throw 'Missing field "$name"';
		return field;
	}

	static function requiredString(value:Dynamic, name:String):String {
		var field = required(value, name);
		if (!Std.isOfType(field, String))
			throw 'Field "$name" must be a string';
		return cast field;
	}

	static function requiredInt(value:Dynamic, name:String):Int {
		var field = required(value, name);
		if (!Std.isOfType(field, Int))
			throw 'Field "$name" must be an integer';
		return cast field;
	}

	static function response(id:Dynamic, result:Dynamic):String
		return Json.stringify({jsonrpc: "2.0", id: id, result: result});

	static function notification(method:String, params:Dynamic):String
		return Json.stringify({jsonrpc: "2.0", method: method, params: params});

	static function serverRequest(id:String, method:String, params:Dynamic):String
		return Json.stringify({
			jsonrpc: "2.0",
			id: id,
			method: method,
			params: params
		});

	static function error(id:Dynamic, code:Int, message:String):String
		return Json.stringify({jsonrpc: "2.0", id: id, error: {code: code, message: message}});
}
