import editor.LspDispatcher;
import editor.LspProtocol;
import editor.lsp.DocumentStore;
import editor.lsp.DocumentStore.LspDocument;
import haxe.Json;
import compiler.service.CancellationToken;
import compiler.service.LanguageService;
import compiler.service.LanguageService.CompletionItem;

class BlockingLanguageService extends LanguageService {
	public final entered = new sys.thread.Lock();
	public final resume = new sys.thread.Lock();

	public override function complete(path:String, position:Int, ?token:CancellationToken):Array<CompletionItem> {
		entered.release();
		resume.wait();
		return super.complete(path, position, token);
	}
}

class LspProtocolMain {
	static function main():Void {
		var positions = new LspDocument("file:///workspace/Lines.hx", "/workspace/Lines.hx", 1, "one\nthree");
		var converted:Dynamic = positions.position(6);
		if (positions.offset(1, 2) != 6 || converted.line != 1 || converted.character != 2)
			throw "LSP document position conversion is inconsistent";
		var decoded = new DocumentStore().open("file:///workspace/My%20File.hx", 1, "");
		if (decoded.path != "/workspace/My File.hx")
			throw "LSP file URI was not decoded";
		var service = new LanguageService(),
			protocol = new LspProtocol(service);
		service.compiler.enablePublicationTracking();
		var initialized = request(protocol, '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}');
		if (!initialized.result.capabilities.hoverProvider
			|| initialized.result.capabilities.signatureHelpProvider == null
			|| initialized.result.capabilities.textDocumentSync.change != 1)
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
		var callSource = "function add(left:Int, right:Int):Int return left + right; function main():Int return add(20, 22);",
			callUri = "file:///workspace/Call.hx";
		protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: callUri,
					languageId: "haxe",
					version: 1,
					text: callSource
				}
			}
		}));
		var signature = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 6,
			method: "textDocument/signatureHelp",
			params: {textDocument: {uri: callUri}, position: {line: 0, character: callSource.indexOf("22") + 1}}
		}));
		if (signature.result == null
			|| signature.result.signatures[0].label != "add(left:Int, right:Int):Int"
			|| signature.result.activeParameter != 1)
			throw "LSP signature help did not use compiler signature information";
		var completion = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 7,
			method: "textDocument/completion",
			params: {textDocument: {uri: callUri}, position: {line: 0, character: callSource.lastIndexOf("add")}}
		})), foundRankedCall = false;
		for (item in cast(completion.result.items, Array<Dynamic>))
			if (item.label == "add" && item.sortText != null && item.insertText == "add(")
				foundRankedCall = true;
		if (!foundRankedCall)
			throw "LSP completion omitted compiler ranking or insertion metadata";
		var blockingService = new BlockingLanguageService(),
			blockingProtocol = new LspProtocol(blockingService),
			cancelledResponse:String = null,
			cancelledDone = new sys.thread.Lock();
		var dispatcher = new LspDispatcher(blockingProtocol, response -> {
			var parsed:Dynamic = Json.parse(response);
			if (parsed.id == 88) {
				cancelledResponse = response;
				cancelledDone.release();
			}
		}, 4);
		dispatcher.dispatch(Json.stringify({
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
		dispatcher.dispatch(Json.stringify({
			jsonrpc: "2.0",
			id: 88,
			method: "textDocument/completion",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.length}}
		}));
		blockingService.entered.wait();
		dispatcher.dispatch('{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":88}}');
		blockingService.resume.release();
		cancelledDone.wait();
		dispatcher.finish();
		if (Json.parse(cancelledResponse).error.code != -32800)
			throw "LSP did not cancel an active completion request";
		var diagnosticService = new LanguageService(),
			diagnosticProtocol = new LspProtocol(diagnosticService),
			choiceUri = "file:///workspace/shape/Choice.hx",
			consumerUri = "file:///workspace/shapeapp/Main.hx",
			choiceSource = "package workspace.shape; enum Choice { One; }",
			consumerSource = "package workspace.shapeapp; import workspace.shape.Choice; function read(value:Choice):Int return switch value { case Choice.One: 1; }; function main():Int return read(Choice.One);";
		diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: choiceUri,
					languageId: "haxe",
					version: 1,
					text: choiceSource
				}
			}
		}));
		diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: consumerUri,
					languageId: "haxe",
					version: 1,
					text: consumerSource
				}
			}
		}));
		var invalidated = diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: choiceUri, version: 2}, contentChanges: [{text: "package workspace.shape; enum Choice { One; Two; }"}]}
		}));
		if (invalidated.length != 1)
			throw 'expected one dependent diagnostic publication, got ${invalidated.length}';
		var invalidatedMessage:Dynamic = Json.parse(invalidated[0]);
		if (invalidatedMessage.params.uri != consumerUri
			|| invalidatedMessage.params.version != 1
			|| invalidatedMessage.params.diagnostics.length == 0)
			throw "dependent enum change did not publish versioned consumer diagnostics";
		var recovered = diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: choiceUri, version: 3}, contentChanges: [{text: choiceSource}]}
		}));
		if (recovered.length != 1)
			throw "diagnostic recovery did not publish exactly one clearing notification";
		var recoveredMessage:Dynamic = Json.parse(recovered[0]);
		if (recoveredMessage.params.uri != consumerUri || recoveredMessage.params.diagnostics.length != 0)
			throw "diagnostic recovery did not clear the dependent module";
		var duplicate = diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: choiceUri, version: 4}, contentChanges: [{text: choiceSource}]}
		}));
		if (duplicate.length != 0)
			throw "unchanged diagnostics were published more than once";
		diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didClose",
			params: {textDocument: {uri: consumerUri}}
		}));
		var closedDependent = diagnosticProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: choiceUri, version: 5}, contentChanges: [{text: "package workspace.shape; enum Choice { One; Two; }"}]}
		}));
		if (closedDependent.length != 1)
			throw "closed dependent diagnostic was not published";
		var closedMessage:Dynamic = Json.parse(closedDependent[0]);
		if (closedMessage.params.uri != consumerUri || Reflect.hasField(closedMessage.params, "version"))
			throw "closed document diagnostic incorrectly included an LSP version";
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
		var documentChanges:Array<Dynamic> = renamed.result.documentChanges;
		if (documentChanges.length != 1
			|| documentChanges[0].textDocument.uri != uri
			|| documentChanges[0].textDocument.version != 1
			|| documentChanges[0].edits.length != 2)
			throw "LSP rename did not return a workspace edit";
		var staleChange = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: uri, version: 1}, contentChanges: [{text: "invalid"}]}
		}));
		if (staleChange.length != 0)
			throw "LSP accepted an out-of-order document version";
		var state = service.compiler.modules.get("workspace.Main");
		if (!state.pendingIrFunctions.exists("main"))
			throw 'Language analysis did not defer IR: pending=${[for (name in state.pendingIrFunctions.keys()) name]}, typed=${[for (name in state.typedFunctions.keys()) name]}';
		var build = service.compile("workspace.Main");
		state = service.compiler.modules.get("workspace.Main");
		if (build.regenerated.indexOf("main") < 0 || state.pendingIrFunctions.exists("main"))
			throw 'Runtime build did not lower deferred IR: regenerated=${build.regenerated}, pending=${[for (name in state.pendingIrFunctions.keys()) name]}';
		var broken = "function main(:Int { return 0; }";
		protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: uri, version: 2}, contentChanges: [{text: broken}]}
		}));
		var staleRename = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			id: 5,
			method: "textDocument/rename",
			params: {textDocument: {uri: uri}, position: {line: 0, character: 10}, newName: "other"}
		}));
		if (staleRename.length != 1 || Json.parse(staleRename[0]).error.code != -32801)
			throw "LSP rename did not reject a stale semantic snapshot";
		if (protocol.handle('{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":999}}').length != 0)
			throw "LSP cancellation notification produced a response";
		var lifecycle = new LspProtocol(),
			shutdown = lifecycle.handle('{"jsonrpc":"2.0","id":20,"method":"shutdown"}');
		if (shutdown.length != 1 || Json.parse(shutdown[0]).result != null)
			throw "LSP shutdown did not return a null result";
		var afterShutdown = lifecycle.handle('{"jsonrpc":"2.0","id":21,"method":"textDocument/hover","params":{}}');
		if (afterShutdown.length != 1 || Json.parse(afterShutdown[0]).error.code != -32600)
			throw "LSP accepted a request after shutdown";
		if (lifecycle.handle('{"jsonrpc":"2.0","method":"exit"}').length != 0 || !lifecycle.shouldExit())
			throw "LSP exit lifecycle was not recorded";
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
