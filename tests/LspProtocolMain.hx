import editor.LspDispatcher;
import editor.LspProtocol;
import editor.lsp.DocumentStore;
import editor.lsp.DocumentStore.LspDocument;
import haxe.Json;
import haxe.io.Path;
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

	public override function completeResult(path:String, position:Int, ?token:CancellationToken):compiler.service.LanguageService.CompletionResult {
		entered.release();
		resume.wait();
		return super.completeResult(path, position, token);
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
		var initialized = request(protocol,
			'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"textDocument":{"completion":{"completionItem":{"snippetSupport":true}}}}}}');
		if (!initialized.result.capabilities.hoverProvider
			|| initialized.result.capabilities.signatureHelpProvider == null
			|| initialized.result.capabilities.textDocumentSync.change != 1
			|| !initialized.result.capabilities.documentHighlightProvider
			|| initialized.result.capabilities.semanticTokensProvider.legend.tokenTypes[12] != "function"
			|| initialized.result.capabilities.codeActionProvider.codeActionKinds[0] != "quickfix"
			|| !initialized.result.capabilities.workspaceSymbolProvider.resolveProvider
			|| !initialized.result.capabilities.inlayHintProvider
			|| !initialized.result.capabilities.callHierarchyProvider)
			throw "LSP initialization capabilities are incomplete";
		var watcherRegistration = protocol.handle('{"jsonrpc":"2.0","method":"initialized","params":{}}');
		if (watcherRegistration.length != 1
			|| Json.parse(watcherRegistration[0]).method != "client/registerCapability"
			|| Json.parse(watcherRegistration[0]).params.registrations[0].registerOptions.watchers.length != 3)
			throw "LSP did not register project and source file watchers";
		if (protocol.handle('{"jsonrpc":"2.0","id":"haxeon/register-watchers","result":null}').length != 0)
			throw "LSP did not accept the client watcher-registration response";
		var fixtureRoot = sys.FileSystem.absolutePath("tests/fixtures/pragtical"),
			fixtureMainPath = Path.join([fixtureRoot, "pragtical/app/LspFixture.hx"]),
			fixtureMainUri = "file://" + fixtureMainPath,
			fixtureSource = sys.io.File.getContent(fixtureMainPath),
			fixtureDocument = new LspDocument(fixtureMainUri, fixtureMainPath, 1, fixtureSource),
			projectProtocol = new LspProtocol();
		request(projectProtocol, Json.stringify({
			jsonrpc: "2.0",
			id: 40,
			method: "initialize",
			params: {rootUri: "file://" + fixtureRoot}
		}));
		if (projectProtocol.project.configurations.length != 1
			|| !projectProtocol.project.hasDiskSource(Path.join([fixtureRoot, "pragtical/plugins/SearchPlugin.hx"])))
			throw "LSP initialization did not discover the Haxe project";
		var workspaceMatches = request(projectProtocol, Json.stringify({
			jsonrpc: "2.0",
			id: 401,
			method: "workspace/symbol",
			params: {query: "SearchPlugin"}
		}));
		var searchPluginSymbol:Dynamic = null;
		for (symbol in cast(workspaceMatches.result, Array<Dynamic>))
			if (symbol.name == "SearchPlugin")
				searchPluginSymbol = symbol;
		if (searchPluginSymbol == null || Reflect.hasField(searchPluginSymbol.location, "range"))
			throw "workspace symbols did not index an unopened project source lazily";
		var resolvedWorkspace = request(projectProtocol,
			Json.stringify({jsonrpc: "2.0", id: 402, method: "workspaceSymbol/resolve", params: searchPluginSymbol}));
		if (!StringTools.endsWith(resolvedWorkspace.result.location.uri, "/pragtical/plugins/SearchPlugin.hx")
			|| resolvedWorkspace.result.location.range == null)
			throw "workspace symbol resolve did not map the exact disk location";
		projectProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: fixtureMainUri,
					languageId: "haxe",
					version: 1,
					text: fixtureSource
				}
			}
		}));
		var importedTypeOffset = fixtureSource.indexOf("Document"),
			importedDefinition = request(projectProtocol, Json.stringify({
				jsonrpc: "2.0",
				id: 41,
				method: "textDocument/definition",
				params: {textDocument: {uri: fixtureMainUri}, position: fixtureDocument.position(importedTypeOffset + 2)}
			}));
		if (importedDefinition.result == null || !StringTools.endsWith(importedDefinition.result.uri, "/pragtical/api/Document.hx"))
			throw "project-backed definition did not resolve an unopened dependency";
		var memberOffset = fixtureSource.indexOf("document.selection") + "document.".length,
			projectCompletion = request(projectProtocol, Json.stringify({
				jsonrpc: "2.0",
				id: 42,
				method: "textDocument/completion",
				params: {textDocument: {uri: fixtureMainUri}, position: fixtureDocument.position(memberOffset)}
			})),
			hasUnopenedMember = false;
		for (item in cast(projectCompletion.result.items, Array<Dynamic>))
			if (item.label == "name")
				hasUnopenedMember = true;
		if (!hasUnopenedMember)
			throw "project-backed completion omitted members from unopened dependencies";
		var watchRoot = "/tmp/haxeon-lsp-watch-" + Std.string(Std.int(Sys.time() * 1000000)),
			watchSourceRoot = Path.join([watchRoot, "src"]),
			watchAppRoot = Path.join([watchSourceRoot, "app"]),
			watchLibRoot = Path.join([watchSourceRoot, "lib"]),
			watchMainPath = Path.join([watchAppRoot, "Main.hx"]),
			watchHelperPath = Path.join([watchLibRoot, "Helper.hx"]),
			watchConfigPath = Path.join([watchRoot, "haxe.json"]),
			watchMainSource = "package app; import lib.Helper;\n#if watcher && !missing\nfunction buildSelected():Int return 1;\n#else\nfunction wrongBuild():Int return 0;\n#end\nfunction main():Int { var helper = new Helper(); return helper.answer(); }";
		sys.FileSystem.createDirectory(watchRoot);
		sys.FileSystem.createDirectory(watchSourceRoot);
		sys.FileSystem.createDirectory(watchAppRoot);
		sys.FileSystem.createDirectory(watchLibRoot);
		sys.io.File.saveContent(watchConfigPath, '{"classPath":["src"],"main":"app.Main","defines":["watcher"]}');
		sys.io.File.saveContent(watchMainPath, watchMainSource);
		sys.io.File.saveContent(watchHelperPath, "package lib; class Helper { public function new() {} public function answer():Int return 1; }");
		var watchProtocol = new LspProtocol(),
			watchMainUri = "file://" + watchMainPath,
			watchHelperUri = "file://" + watchHelperPath,
			watchDocument = new LspDocument(watchMainUri, watchMainPath, 1, watchMainSource);
		request(watchProtocol, Json.stringify({
			jsonrpc: "2.0",
			id: 43,
			method: "initialize",
			params: {rootUri: "file://" + watchRoot}
		}));
		watchProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: watchMainUri,
					languageId: "haxe",
					version: 1,
					text: watchMainSource
				}
			}
		}));
		var buildSymbols = watchProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			id: 430,
			method: "textDocument/documentSymbol",
			params: {textDocument: {uri: watchMainUri}}
		})), hasSelectedBuild = false, hasWrongBuild = false;
		for (symbol in cast(Json.parse(buildSymbols[0]).result, Array<Dynamic>)) {
			if (symbol.name == "buildSelected")
				hasSelectedBuild = true;
			if (symbol.name == "wrongBuild")
				hasWrongBuild = true;
		}
		if (!hasSelectedBuild || hasWrongBuild)
			throw "selected build defines did not control LSP symbols";
		sys.io.File.saveContent(watchHelperPath,
			"package lib; class Helper { public function new() {} public function answer():Int return 2; public function diskOnly():Int return 3; }");
		watchProtocol.handle(watchedFileMessage(watchHelperUri, 2));
		watchMainSource = StringTools.replace(watchMainSource, "helper.answer", "helper.diskOnly");
		watchDocument.replace(2, watchMainSource);
		watchProtocol.handle(documentChangeMessage(watchMainUri, 2, watchMainSource));
		if (!definitionTargets(watchProtocol, watchMainUri, watchDocument, "diskOnly", 44, watchHelperUri))
			throw "external source edit did not refresh unopened navigation";
		var overlaySource = "package lib; class Helper { public function new() {} public function answer():Int return 4; public function overlayOnly():Int return 5; }";
		watchProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {
				textDocument: {
					uri: watchHelperUri,
					languageId: "haxe",
					version: 1,
					text: overlaySource
				}
			}
		}));
		watchMainSource = StringTools.replace(watchMainSource, "helper.diskOnly", "helper.overlayOnly");
		watchDocument.replace(3, watchMainSource);
		watchProtocol.handle(documentChangeMessage(watchMainUri, 3, watchMainSource));
		sys.io.File.saveContent(watchHelperPath,
			"package lib; class Helper { public function new() {} public function answer():Int return 6; public function newestDisk():Int return 7; }");
		watchProtocol.handle(watchedFileMessage(watchHelperUri, 2));
		if (!definitionTargets(watchProtocol, watchMainUri, watchDocument, "overlayOnly", 45, watchHelperUri))
			throw "disk watcher overrode an open document overlay";
		watchProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didClose",
			params: {textDocument: {uri: watchHelperUri}}
		}));
		watchMainSource = StringTools.replace(watchMainSource, "helper.overlayOnly", "helper.newestDisk");
		watchDocument.replace(4, watchMainSource);
		watchProtocol.handle(documentChangeMessage(watchMainUri, 4, watchMainSource));
		if (!definitionTargets(watchProtocol, watchMainUri, watchDocument, "newestDisk", 47, watchHelperUri))
			throw "closing an overlay did not restore the newest disk source";
		sys.FileSystem.deleteFile(watchHelperPath);
		watchProtocol.handle(watchedFileMessage(watchHelperUri, 3));
		if (definitionTargets(watchProtocol, watchMainUri, watchDocument, "newestDisk", 48, watchHelperUri))
			throw "deleted source remained in semantic completion";
		var alternateRoot = Path.join([watchRoot, "alternate"]);
		sys.FileSystem.createDirectory(alternateRoot);
		sys.io.File.saveContent(Path.join([alternateRoot, "Alternate.hx"]), "class Alternate {}");
		sys.io.File.saveContent(watchConfigPath, '{"classPath":["alternate"]}');
		watchProtocol.handle(watchedFileMessage("file://" + watchConfigPath, 2));
		if (!watchProtocol.project.hasDiskSource(Path.join([alternateRoot, "Alternate.hx"])))
			throw "Haxe configuration change did not refresh source roots";
		var secondRoot = Path.join([watchRoot, "second"]),
			secondConfigPath = Path.join([watchRoot, "second.hxml"]);
		sys.FileSystem.createDirectory(secondRoot);
		sys.io.File.saveContent(Path.join([secondRoot, "Second.hx"]), "class Second {}");
		sys.io.File.saveContent(secondConfigPath, "-cp second\n-main Second\n");
		watchProtocol.handle(watchedFileMessage("file://" + secondConfigPath, 1));
		if (watchProtocol.project.configurations.length != 2
			|| watchProtocol.project.configurations[0].id == watchProtocol.project.configurations[1].id)
			throw "discovered Haxe builds did not receive stable distinct identities";
		watchProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "workspace/didChangeConfiguration",
			params: {settings: {haxeon: {configuration: secondConfigPath}}}
		}));
		if (watchProtocol.project.configurationFor(Path.join([alternateRoot, "Alternate.hx"])).file != secondConfigPath)
			throw "explicit Haxe build selection did not override path ownership";
		deleteTree(watchRoot);
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
		var highlights = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 5,
			method: "textDocument/documentHighlight",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.lastIndexOf("answer") + 2}}
		}));
		if (highlights.result.length != 2 || highlights.result[0].kind != 3 || highlights.result[1].kind != 2)
			throw "LSP document highlights did not classify declaration and read occurrences";
		var localHints = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 50,
			method: "textDocument/inlayHint",
			params: {textDocument: {uri: uri}, range: {start: {line: 0, character: 0}, end: {line: 0, character: source.length}}}
		})), inferredLocal = false;
		for (hint in cast(localHints.result, Array<Dynamic>))
			if (hint.kind == 1 && hint.label == ": Int" && hint.position.character == source.indexOf("answer") + "answer".length)
				inferredLocal = true;
		if (!inferredLocal)
			throw "LSP inlay hints omitted an inferred local type";
		var semantic = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 51,
			method: "textDocument/semanticTokens/full",
			params: {textDocument: {uri: uri}}
		}));
		if (!hasSemanticToken(semantic.result.data, 0, source.indexOf("main"), 12, 1)
			|| !hasSemanticToken(semantic.result.data, 0, source.indexOf("answer"), 8, 1)
			|| !hasSemanticToken(semantic.result.data, 0, source.lastIndexOf("answer"), 8, 0)
			|| !hasSemanticToken(semantic.result.data, 0, source.indexOf("42"), 19, 0))
			throw "LSP semantic tokens omitted typed declarations, references, or literals";
		var brokenUri = "file:///workspace/BrokenString.hx",
			brokenSource = "function main():String return \"broken";
		protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {textDocument: {uri: brokenUri, languageId: "haxe", version: 1, text: brokenSource}}
		}));
		var actions = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 52,
			method: "textDocument/codeAction",
			params: {
				textDocument: {uri: brokenUri},
				range: {start: {line: 0, character: 0}, end: {line: 0, character: brokenSource.length}},
				context: {diagnostics: []}
			}
		}));
		if (actions.result.length != 1
			|| actions.result[0].title != "Close string literal"
			|| actions.result[0].kind != "quickfix"
			|| actions.result[0].diagnostics[0].code != "E0001"
			|| actions.result[0].edit.documentChanges[0].textDocument.version != 1
			|| actions.result[0].edit.documentChanges[0].edits[0].newText != "\"")
			throw "LSP code actions did not expose the compiler-authored lexical fix";
		var callSource = "/** Adds values.\n * @param left First value.\n * @param right Second value.\n * @return the sum.\n * @deprecated Use sum.\n */\nfunction add(left:Int, right:Int):Int return left + right; function main():Int return add(20, 22) + add(1, 2);",
			callUri = "file:///workspace/Call.hx", callDocument = new LspDocument(callUri, "/workspace/Call.hx", 1, callSource);
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
			params: {textDocument: {uri: callUri}, position: callDocument.position(callSource.indexOf("22") + 1)}
		}));
		if (signature.result == null
			|| signature.result.signatures[0].label != "add(left:Int, right:Int):Int"
			|| signature.result.signatures[0].documentation.value.indexOf("Adds values") < 0
			|| signature.result.signatures[0].parameters[0].documentation.value != "First value."
			|| signature.result.activeParameter != 1)
			throw "LSP signature help did not use compiler signature information";
		var callHints = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 61,
			method: "textDocument/inlayHint",
			params: {textDocument: {uri: callUri}, range: {start: {line: 0, character: 0}, end: callDocument.position(callSource.length)}}
		})), hasLeftHint = false, hasRightHint = false;
		for (hint in cast(callHints.result, Array<Dynamic>)) {
			if (hint.kind == 2 && hint.label == "left:" && hint.position.character == callDocument.position(callSource.indexOf("20")).character)
				hasLeftHint = true;
			if (hint.kind == 2 && hint.label == "right:" && hint.position.character == callDocument.position(callSource.indexOf("22")).character)
				hasRightHint = true;
		}
		if (!hasLeftHint || !hasRightHint)
			throw "LSP inlay hints omitted resolved call parameter names";
		var preparedAdd = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 62,
			method: "textDocument/prepareCallHierarchy",
			params: {textDocument: {uri: callUri}, position: callDocument.position(callSource.indexOf("add") + 1)}
		})), preparedMain = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 63,
			method: "textDocument/prepareCallHierarchy",
			params: {textDocument: {uri: callUri}, position: callDocument.position(callSource.indexOf("main") + 1)}
		}));
		if (preparedAdd.result == null || preparedMain.result == null)
			throw "LSP did not prepare callable hierarchy items";
		var incoming = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 64,
			method: "callHierarchy/incomingCalls",
			params: {item: preparedAdd.result[0]}
		})), outgoing = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 65,
			method: "callHierarchy/outgoingCalls",
			params: {item: preparedMain.result[0]}
		}));
		if (incoming.result.length != 1
			|| incoming.result[0].from.name != "main"
			|| incoming.result[0].fromRanges.length != 2
			|| outgoing.result.length != 1
			|| outgoing.result[0].to.name != "add"
			|| outgoing.result[0].fromRanges.length != 2)
			throw "LSP call hierarchy did not aggregate repeated incoming and outgoing call sites";
		var completion = request(protocol, Json.stringify({
			jsonrpc: "2.0",
			id: 7,
			method: "textDocument/completion",
			params: {textDocument: {uri: callUri}, position: callDocument.position(callSource.lastIndexOf("add") + 2)}
		})), foundRankedCall = false, addCompletionItem:Dynamic = null;
		for (item in cast(completion.result.items, Array<Dynamic>))
			if (item.label == "add"
				&& item.sortText != null
				&& item.insertTextFormat == 2
				&& item.textEdit.newText == "add(${1})"
				&& item.textEdit.range.start.character == callDocument.position(callSource.lastIndexOf("add")).character
				&& item.textEdit.range.end.character == callDocument.position(callSource.lastIndexOf("add") + 2).character) {
				foundRankedCall = true;
				addCompletionItem = item;
			}
		if (!foundRankedCall)
			throw "LSP completion omitted compiler ranking or insertion metadata";
		var resolvedAdd = request(protocol, Json.stringify({jsonrpc: "2.0", id: 76, method: "completionItem/resolve", params: addCompletionItem}));
		if (resolvedAdd.result.documentation.kind != "markdown" || resolvedAdd.result.documentation.value.indexOf("**Deprecated.** Use sum.") < 0)
			throw "completion resolve did not reuse compiler-owned documentation";
		var addHoverPosition = callDocument.position(callSource.indexOf("add") + 1),
			documentedHover = request(protocol, Json.stringify({
				jsonrpc: "2.0", id: 77, method: "textDocument/hover", params: {textDocument: {uri: callUri}, position: addHoverPosition}
			}));
		if (documentedHover.result.contents.kind != "markdown" || documentedHover.result.contents.value.indexOf("Adds values") < 0)
			throw "hover did not reuse compiler-owned documentation";
		var callSemantic = request(protocol, Json.stringify({
			jsonrpc: "2.0", id: 78, method: "textDocument/semanticTokens/full", params: {textDocument: {uri: callUri}}
		})), addDeclaration = callDocument.position(callSource.indexOf("add"));
		if (!hasSemanticToken(callSemantic.result.data, addDeclaration.line, addDeclaration.character, 12, 17))
			throw "deprecated documentation did not annotate the semantic declaration token";
		var importService = new LanguageService(), importProtocol = new LspProtocol(importService),
			helperPath = "/workspace/tools/Helper.hx", helperUri = "file://" + helperPath,
			importUri = "file:///workspace/ImportMain.hx", importSource = "function main():Int return 0; // Hel";
		importService.update(helperPath, "class Helper { public static function answer():Int return 42; } function main():Int return 0;");
		request(importProtocol, '{"jsonrpc":"2.0","id":70,"method":"initialize","params":{}}');
		importProtocol.handle(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didOpen",
			params: {textDocument: {uri: importUri, languageId: "haxe", version: 1, text: importSource}}
		}));
		var importCompletion = request(importProtocol, Json.stringify({
			jsonrpc: "2.0",
			id: 71,
			method: "textDocument/completion",
			params: {textDocument: {uri: importUri}, position: {line: 0, character: importSource.length}}
		})), helperItem:Dynamic = null;
		for (item in cast(importCompletion.result.items, Array<Dynamic>))
			if (item.label == "Helper")
				helperItem = item;
		if (helperItem == null || helperItem.data == null || helperItem.data.importPath != "workspace.tools.Helper")
			throw "completion omitted a unique auto-import candidate or its opaque resolve data";
		var resolvedHelper = request(importProtocol, Json.stringify({jsonrpc: "2.0", id: 72, method: "completionItem/resolve", params: helperItem}));
		if (resolvedHelper.result.documentation.value.indexOf(helperPath) < 0
			|| resolvedHelper.result.additionalTextEdits.length != 1
			|| resolvedHelper.result.additionalTextEdits[0].newText != "import workspace.tools.Helper;\n")
			throw "completion resolve omitted documentation or the deterministic import edit";
		var importedSource = "import workspace.tools.Helper;\nfunction main():Int return 0; // Hel";
		importProtocol.handle(documentChangeMessage(importUri, 2, importedSource));
		var importedCompletion = request(importProtocol, Json.stringify({
			jsonrpc: "2.0",
			id: 74,
			method: "textDocument/completion",
			params: {textDocument: {uri: importUri}, position: {line: 1, character: "function main():Int return 0; // Hel".length}}
		})), importedHelper:Dynamic = null;
		for (item in cast(importedCompletion.result.items, Array<Dynamic>))
			if (item.label == "Helper")
				importedHelper = item;
		if (importedHelper == null)
			throw "completion omitted an already imported workspace symbol";
		var resolvedImported = request(importProtocol, Json.stringify({jsonrpc: "2.0", id: 75, method: "completionItem/resolve", params: importedHelper}));
		if (importedHelper.data.importPath != null || resolvedImported.result.additionalTextEdits.length != 0)
			throw "completion resolve proposed a duplicate import";
		var staleResolve = importProtocol.handle(Json.stringify({jsonrpc: "2.0", id: 73, method: "completionItem/resolve", params: helperItem}));
		if (staleResolve.length != 1 || Json.parse(staleResolve[0]).error.code != -32801)
			throw "completion resolve accepted stale candidate data";
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
		var foregroundService = new LanguageService(),
			foregroundProtocol = new LspProtocol(foregroundService),
			foregroundResponse:String = null,
			foregroundDone = new sys.thread.Lock(),
			foregroundDispatcher = new LspDispatcher(foregroundProtocol, response -> {
				var parsed:Dynamic = Json.parse(response);
				if (parsed.id == 89) {
					foregroundResponse = response;
					foregroundDone.release();
				}
			}, 4, 5000);
		foregroundDispatcher.dispatch(Json.stringify({
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
		foregroundDispatcher.dispatch(Json.stringify({
			jsonrpc: "2.0",
			id: 89,
			method: "textDocument/completion",
			params: {textDocument: {uri: uri}, position: {line: 0, character: source.length}}
		}));
		foregroundDone.wait();
		foregroundDispatcher.finish();
		var foregroundCompletion:Dynamic = Json.parse(foregroundResponse),
			foregroundHasMain = false;
		for (item in cast(foregroundCompletion.result.items, Array<Dynamic>))
			if (item.label == "main")
				foregroundHasMain = true;
		if (!foregroundHasMain || foregroundProtocol.lastForegroundAnalysisMs < 0)
			throw "first-open completion did not demand a current semantic snapshot";
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
		var scheduledService = new LanguageService(),
			scheduledProtocol = new LspProtocol(scheduledService),
			scheduledMessages:Array<String> = [],
			scheduledDiagnostics = new sys.thread.Lock(),
			scheduledDispatcher = new LspDispatcher(scheduledProtocol, response -> {
				scheduledMessages.push(response);
				var parsed:Dynamic = Json.parse(response);
				if (parsed.method == "textDocument/publishDiagnostics" && parsed.params.uri == consumerUri)
					scheduledDiagnostics.release();
			}, 16, 20);
		scheduledDispatcher.dispatch(Json.stringify({
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
		scheduledDispatcher.dispatch(Json.stringify({
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
		scheduledDispatcher.dispatch(Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {
				textDocument: {uri: choiceUri, version: 2},
				contentChanges: [{text: "package workspace.shape; enum Choice { One; Two; }"}]
			}
		}));
		scheduledDispatcher.dispatch(Json.stringify({
			jsonrpc: "2.0",
			id: 90,
			method: "textDocument/hover",
			params: {textDocument: {uri: consumerUri}, position: {line: 0, character: 10}}
		}));
		scheduledDiagnostics.wait();
		scheduledDispatcher.finish();
		var interactiveIndex = -1,
			diagnosticIndex = -1,
			latestChoiceVersion = -1,
			scheduledConsumerDiagnostics = -1;
		for (index in 0...scheduledMessages.length) {
			var parsed:Dynamic = Json.parse(scheduledMessages[index]);
			if (parsed.id == 90)
				interactiveIndex = index;
			if (parsed.method == "textDocument/publishDiagnostics") {
				if (parsed.params.uri == choiceUri)
					latestChoiceVersion = parsed.params.version;
				if (parsed.params.uri == consumerUri) {
					diagnosticIndex = index;
					scheduledConsumerDiagnostics = parsed.params.diagnostics.length;
				}
			}
		}
		if (interactiveIndex < 0 || diagnosticIndex <= interactiveIndex)
			throw "interactive LSP request was not prioritized over pending diagnostics";
		if (latestChoiceVersion != 2 || scheduledConsumerDiagnostics == 0 || scheduledProtocol.lastBackgroundAnalysisMs < 0)
			throw "debounced diagnostics did not publish only the latest document generation";
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

	static function watchedFileMessage(uri:String, type:Int):String
		return Json.stringify({jsonrpc: "2.0", method: "workspace/didChangeWatchedFiles", params: {changes: [{uri: uri, type: type}]}});

	static function documentChangeMessage(uri:String, version:Int, source:String):String
		return Json.stringify({
			jsonrpc: "2.0",
			method: "textDocument/didChange",
			params: {textDocument: {uri: uri, version: version}, contentChanges: [{text: source}]}
		});

	static function definitionTargets(protocol:LspProtocol, uri:String, document:LspDocument, symbol:String, id:Int, expectedUri:String):Bool {
		var responses = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			id: id,
			method: "textDocument/definition",
			params: {textDocument: {uri: uri}, position: document.position(document.source.indexOf(symbol) + 2)}
		}));
		if (responses.length != 1)
			return false;
		var response:Dynamic = Json.parse(responses[0]);
		return response.error == null && response.result != null && response.result.uri == expectedUri;
	}

	static function hasSemanticToken(raw:Dynamic, expectedLine:Int, expectedCharacter:Int, expectedType:Int, expectedModifiers:Int):Bool {
		var data:Array<Int> = cast raw, line = 0, character = 0, index = 0;
		while (index < data.length) {
			line += data[index];
			character = data[index] == 0 ? character + data[index + 1] : data[index + 1];
			if (line == expectedLine && character == expectedCharacter && data[index + 3] == expectedType && data[index + 4] == expectedModifiers)
				return true;
			index += 5;
		}
		return false;
	}

	static function deleteTree(path:String):Void {
		if (!sys.FileSystem.exists(path))
			return;
		if (!sys.FileSystem.isDirectory(path)) {
			sys.FileSystem.deleteFile(path);
			return;
		}
		for (name in sys.FileSystem.readDirectory(path))
			deleteTree(Path.join([path, name]));
		sys.FileSystem.deleteDirectory(path);
	}
}
