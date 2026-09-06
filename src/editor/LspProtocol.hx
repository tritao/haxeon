package editor;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.service.LanguageService;
import editor.lsp.DocumentStore;
import editor.lsp.DocumentStore.LspDocument;
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
	final service:LanguageService;
	final documents = new DocumentStore();
	final publishedDiagnostics:Map<String, String> = [];
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
			return id == null ? [] : [error(id, -32600, "Invalid Request")];
		if (shutdownRequested && method != "exit")
			return id == null ? [] : [error(id, -32600, "Server has shut down")];
		try {
			return switch method {
				case "initialize": [response(id, initializeResult())];
				case "initialized": [];
				case "shutdown":
					shutdownRequested = true;
					[response(id, null)];
				case "exit":
					exitRequested = true;
					[];
				case "textDocument/didOpen": synchronize(request, true);
				case "textDocument/didChange": synchronize(request, false);
				case "textDocument/didClose": close(request);
				case "textDocument/documentSymbol": [response(id, documentSymbols(request))];
				case "textDocument/completion": [response(id, completion(request))];
				case "textDocument/hover": [response(id, hover(request))];
				case "textDocument/signatureHelp": [response(id, signatureHelp(request))];
				case "textDocument/definition": [response(id, definition(request))];
				case "textDocument/references": [response(id, references(request))];
				case "textDocument/prepareRename": [response(id, prepareRename(request))];
				case "textDocument/rename": [response(id, rename(request))];
				case "$/cancelRequest": [];
				default: id == null ? [] : [error(id, -32601, 'Method not found: $method')];
			};
		} catch (failure:LspRequestError) {
			return id == null ? [] : [error(id, failure.code, failure.message)];
		} catch (failure:Dynamic) {
			return id == null ? [] : [error(id, -32603, Std.string(failure))];
		}
	}

	public function shouldExit():Bool
		return exitRequested;

	function initializeResult():Dynamic
		return {
			capabilities: {
				positionEncoding: "utf-16",
				textDocumentSync: {openClose: true, change: 1},
				documentSymbolProvider: true,
				completionProvider: {triggerCharacters: ["."]},
				hoverProvider: true,
				signatureHelpProvider: {triggerCharacters: ["(", ","]},
				definitionProvider: true,
				referencesProvider: true,
				renameProvider: {prepareProvider: true}
			},
			serverInfo: {name: "haxeon", version: "0.1.0"}
		};

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
		var path = document.path;
		service.update(path, document.source);
		var changedModule = ModulePath.fromFile(path),
			targets = service.compiler.dependentModules(changedModule);
		if (targets.length == 0)
			targets.push(changedModule);
		for (target in targets)
			try
				service.analyze(target)
			catch (_:CompileError) {}
		return diagnosticNotifications();
	}

	function close(request:Dynamic):Array<String> {
		var uri = documentUri(request);
		documents.close(uri);
		publishedDiagnostics.set(uri, "");
		return [notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: []})];
	}

	function diagnosticNotifications():Array<String> {
		var result:Array<String> = [],
			states = [for (state in service.compiler.modules) state];
		states.sort(function(left, right) return Reflect.compare(left.source.path, right.source.path));
		for (state in states) {
			var uri = documents.uri(state.source.path),
				fingerprint = diagnosticFingerprint(state.diagnostics);
			if (publishedDiagnostics.get(uri) == fingerprint)
				continue;
			publishedDiagnostics.set(uri, fingerprint);
			var params:Dynamic = {
				uri: uri,
				diagnostics: [for (diagnostic in state.diagnostics) diagnosticJson(diagnostic)]
			};
			var open = documents.forPath(state.source.path);
			if (open != null)
				Reflect.setField(params, "version", open.version);
			result.push(notification("textDocument/publishDiagnostics", params));
		}
		return result;
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

	function documentSymbols(request:Dynamic):Array<Dynamic> {
		var document = document(request);
		requireCurrent(document);
		return [
			for (symbol in service.documentSymbols(document.path))
				{
					name: symbol.name,
					kind: symbolKind(symbol.kind),
					detail: symbol.detail,
					range: document.range(symbol.span.start, symbol.span.end),
					selectionRange: document.range(symbol.span.start, symbol.span.end)
				}
		];
	}

	function completion(request:Dynamic):Dynamic {
		var document = document(request),
			offset = positionOffset(document, position(request));
		return {
			isIncomplete: false,
			items: [
				for (item in service.complete(document.path, offset))
					{
						label: item.label,
						kind: completionKind(item.kind),
						detail: item.detail,
						sortText: item.sortText,
						insertText: item.insertText
					}
			]
		};
	}

	function hover(request:Dynamic):Dynamic {
		var document = document(request),
			value = service.hover(document.path, positionOffset(document, position(request)));
		return value == null ? null : {contents: {kind: "plaintext", value: value}};
	}

	function signatureHelp(request:Dynamic):Dynamic {
		var document = document(request),
			value = service.signatureHelp(document.path, positionOffset(document, position(request)));
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

	function definition(request:Dynamic):Dynamic {
		var document = document(request);
		requireCurrent(document);
		var location = service.definition(document.path, positionOffset(document, position(request)));
		return location == null ? null : locationJson(location.path, location.span.start, location.span.end);
	}

	function references(request:Dynamic):Array<Dynamic> {
		var document = document(request);
		requireCurrent(document);
		var locations = service.references(document.path, positionOffset(document, position(request)));
		return [
			for (location in locations)
				locationJson(location.path, location.span.start, location.span.end)
		];
	}

	function prepareRename(request:Dynamic):Dynamic {
		var document = document(request);
		requireCurrent(document);
		var offset = positionOffset(document, position(request));
		for (token in service.compiler.modules.get(ModulePath.fromFile(document.path)).tokens)
			if (offset >= token.span.start && offset <= token.span.end && Std.string(token.kind) == "Identifier")
				return {range: document.range(token.span.start, token.span.end), placeholder: token.text};
		return null;
	}

	function rename(request:Dynamic):Dynamic {
		var document = document(request);
		requireCurrent(document);
		var params:Dynamic = required(request, "params"),
			edits = service.rename(document.path, positionOffset(document, position(request)), requiredString(params, "newName")),
			grouped:Map<String, Array<Dynamic>> = [],
			targets:Map<String, LspDocument> = [];
		for (edit in edits) {
			if (edit.stale)
				throw new LspRequestError(-32801, "Rename result is based on stale source");
			var uri = documents.uri(edit.path),
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
		return {uri: documents.uri(path), range: target.range(start, end)};
	}

	function documentForPath(path:String):LspDocument {
		var open = documents.forPath(path);
		if (open != null)
			return open;
		var state = service.compiler.modules.get(ModulePath.fromFile(path));
		if (state == null)
			throw 'Unknown source path: $path';
		return new LspDocument(documents.uri(path), path, state.revision, state.source.text);
	}

	function document(request:Dynamic):LspDocument
		return documents.get(documentUri(request));

	function requireCurrent(document:LspDocument):Void {
		if (!service.isCurrent(document.path))
			throw new LspRequestError(-32801, "Semantic snapshot does not match the current document version");
	}

	static function documentUri(request:Dynamic):String
		return requiredString(required(required(request, "params"), "textDocument"), "uri");

	static function position(request:Dynamic):Dynamic
		return required(required(request, "params"), "position");

	static function positionOffset(document:LspDocument, position:Dynamic):Int
		return document.offset(requiredInt(position, "line"), requiredInt(position, "character"));

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

	static function error(id:Dynamic, code:Int, message:String):String
		return Json.stringify({jsonrpc: "2.0", id: id, error: {code: code, message: message}});
}
