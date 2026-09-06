import editor.LspProtocol;
import haxe.Json;
import compiler.service.LanguageService;

class LspProtocolMain {
	static function main():Void {
		var service = new LanguageService(),
			protocol = new LspProtocol(service);
		service.compiler.enablePublicationTracking();
		var initialized = request(protocol, '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}');
		if (!initialized.result.capabilities.hoverProvider || initialized.result.capabilities.textDocumentSync.change != 1)
			throw "LSP initialization capabilities are incomplete";
		var source = "function main():Int { var answer = 42; return answer; }",
			uri = "file:///workspace/Main.hx";
		var opened = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: uri,
					languageId: "haxe",
					version: 1,
					text: source
				}
			}
		}));
		if (opened.length != 1 || Json.parse(opened[0]).method != "textDocument/publishDiagnostics")
			throw "LSP didOpen did not publish diagnostics";
		if (service.compiler.publicationStatus().hasPendingRevision)
			throw "LSP document analysis published a runtime candidate";
		var hover = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 2,
			method: "textDocument/hover",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.indexOf("main") + 4}}
		}));
		if (hover.result == null || hover.result.contents.value != "main():Int")
			throw "LSP hover did not use the compiler language service";
		var definition = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 3,
			method: "textDocument/definition",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.lastIndexOf("answer") + 2}}
		}));
		if (definition.result == null || definition.result.uri != uri)
			throw "LSP definition did not return a location";
		var renamed = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 4,
			method: "textDocument/rename",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.lastIndexOf("answer") + 2}, newName: "result"}
		}));
		var edits:Array<Dynamic> = Reflect.field(renamed.result.changes, uri);
		if (edits == null || edits.length != 2)
			throw "LSP rename did not return a workspace edit";
		var state = service.compiler.modules.get("workspace.Main");
		if (!state.pendingIrFunctions.exists("main"))
			throw 'Language analysis did not defer IR: pending=${[for (name in state.pendingIrFunctions.keys()) name]}, typed=${[for (name in state.typedFunctions.keys()) name]}';
		var build = service.compile("workspace.Main");
		state = service.compiler.modules.get("workspace.Main");
		if (build.regenerated.indexOf("main") < 0 || state.pendingIrFunctions.exists("main"))
			throw 'Runtime build did not lower deferred IR: regenerated=${build.regenerated}, pending=${[for (name in state.pendingIrFunctions.keys()) name]}';
		Sys.println("PASS: standard LSP adapter maps compiler language queries");
	}

	static function request(protocol:LspProtocol, message:String):Dynamic {
		var responses = protocol.handle(message);
		if (responses.length != 1)
			throw "Expected one LSP response";
		var result:Dynamic = Json.parse(responses[0]);
		if (result.error != null)
			throw result.error.message;
		return result;
	}
}
