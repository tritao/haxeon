package editor;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.service.LanguageService;
import haxe.Json;

/** Minimal standard LSP adapter over the compiler-owned language service. */
class LspProtocol {
	final service:LanguageService;
	final documents:Map<String, {path:String, version:Int, source:String}> = [];
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
				case "textDocument/definition": [response(id, definition(request))];
				case "textDocument/references": [response(id, references(request))];
				case "textDocument/prepareRename": [response(id, prepareRename(request))];
				case "textDocument/rename": [response(id, rename(request))];
				case "$/cancelRequest": [];
				default: id == null ? [] : [error(id, -32601, 'Method not found: $method')];
			};
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
		var path = uriPath(uri);
		documents.set(uri, {path: path, version: version, source: source});
		service.update(path, source);
		try
			service.analyze(ModulePath.fromFile(path))
		catch (_:CompileError) {}
		return [
			notification("textDocument/publishDiagnostics", {
				uri: uri,
				version: version,
				diagnostics: [for (diagnostic in service.diagnostics(path)) diagnosticJson(diagnostic)]
			})
		];
	}

	function close(request:Dynamic):Array<String> {
		var uri = documentUri(request);
		documents.remove(uri);
		return [notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: []})];
	}

	function documentSymbols(request:Dynamic):Array<Dynamic> {
		var document = document(request);
		return [
			for (symbol in service.documentSymbols(document.path))
				{
					name: symbol.name,
					kind: symbolKind(symbol.kind),
					detail: symbol.detail,
					range: range(document.source, symbol.span.start, symbol.span.end),
					selectionRange: range(document.source, symbol.span.start, symbol.span.end)
				}
		];
	}

	function completion(request:Dynamic):Dynamic {
		var document = document(request),
			offset = positionOffset(document.source, position(request));
		return {
			isIncomplete: false,
			items: [
				for (item in service.complete(document.path, offset))
					{
						label: item.label,
						kind: completionKind(item.kind),
						detail: item.detail
					}
			]
		};
	}

	function hover(request:Dynamic):Dynamic {
		var document = document(request),
			value = service.hover(document.path, positionOffset(document.source, position(request)));
		return value == null ? null : {contents: {kind: "plaintext", value: value}};
	}

	function definition(request:Dynamic):Dynamic {
		var document = document(request),
			location = service.definition(document.path, positionOffset(document.source, position(request)));
		return location == null ? null : locationJson(location.path, location.span.start, location.span.end);
	}

	function references(request:Dynamic):Array<Dynamic> {
		var document = document(request),
			locations = service.references(document.path, positionOffset(document.source, position(request)));
		return [
			for (location in locations)
				locationJson(location.path, location.span.start, location.span.end)
		];
	}

	function prepareRename(request:Dynamic):Dynamic {
		var document = document(request),
			offset = positionOffset(document.source, position(request));
		for (token in service.compiler.modules.get(ModulePath.fromFile(document.path)).tokens)
			if (offset >= token.span.start && offset <= token.span.end && Std.string(token.kind) == "Identifier")
				return {range: range(document.source, token.span.start, token.span.end), placeholder: token.text};
		return null;
	}

	function rename(request:Dynamic):Dynamic {
		var document = document(request),
			params:Dynamic = required(request, "params"),
			edits = service.rename(document.path, positionOffset(document.source, position(request)), requiredString(params, "newName")),
			changes:Dynamic = {};
		for (edit in edits) {
			var uri = pathUri(edit.path),
				source = sourceForPath(edit.path),
				existing:Array<Dynamic> = Reflect.field(changes, uri);
			if (existing == null) {
				existing = [];
				Reflect.setField(changes, uri, existing);
			}
			existing.push({range: range(source, edit.span.start, edit.span.end), newText: edit.replacement});
		}
		return {changes: changes};
	}

	function locationJson(path:String, start:Int, end:Int):Dynamic
		return {uri: pathUri(path), range: range(sourceForPath(path), start, end)};

	function sourceForPath(path:String):String {
		for (document in documents)
			if (document.path == path)
				return document.source;
		var state = service.compiler.modules.get(ModulePath.fromFile(path));
		return state == null ? "" : state.source.text;
	}

	function document(request:Dynamic):{path:String, version:Int, source:String} {
		var uri = documentUri(request), result = documents.get(uri);
		if (result == null)
			throw 'Document is not open: $uri';
		return result;
	}

	static function documentUri(request:Dynamic):String
		return requiredString(required(required(request, "params"), "textDocument"), "uri");

	static function position(request:Dynamic):Dynamic
		return required(required(request, "params"), "position");

	static function positionOffset(source:String, position:Dynamic):Int {
		var line = requiredInt(position, "line"), character = requiredInt(position, "character"), offset = 0;
		for (_ in 0...line) {
			var newline = source.indexOf("\n", offset);
			if (newline < 0)
				return source.length;
			offset = newline + 1;
		}
		var lineEnd = source.indexOf("\n", offset);
		return Std.int(Math.min(offset + character, lineEnd < 0 ? source.length : lineEnd));
	}

	static function range(source:String, start:Int, end:Int):Dynamic
		return {start: offsetPosition(source, start), end: offsetPosition(source, end)};

	static function offsetPosition(source:String, requested:Int):Dynamic {
		var offset = Std.int(Math.max(0, Math.min(requested, source.length))), line = 0, lineStart = 0;
		for (index in 0...offset)
			if (source.charCodeAt(index) == 10) {
				line++;
				lineStart = index + 1;
			}
		return {line: line, character: offset - lineStart};
	}

	static function diagnosticJson(diagnostic:Diagnostic):Dynamic
		return {
			range: range(diagnostic.span.file.text, diagnostic.span.start, diagnostic.span.end),
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

	static function pathUri(path:String):String
		return StringTools.startsWith(path, "file://") ? path : "file://" + path;

	static function uriPath(uri:String):String
		return StringTools.startsWith(uri, "file://") ? uri.substr(7) : uri;

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
