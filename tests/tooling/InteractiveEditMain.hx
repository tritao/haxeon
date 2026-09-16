import compiler.Source.SourceSpan;
import compiler.service.LanguageService;

/** Exercises the language service as a sequence of real editor updates. */
class InteractiveEditMain {
	static function main():Void {
		var service = new LanguageService(),
			prefix = "class Foo { public function bar(value:Int):Int return value; }\n" + "function main():Void { var foo:Foo = new Foo(); ", tails = [
				"f",
				"fo",
				"foo",
				"foo.",
				"foo.b",
				"foo.ba",
				"foo.bar(",
				"foo.bar(x",
				"foo.bar(x)"
			];

		for (tail in tails) {
			var source = prefix + tail, position = source.length;
			service.update("Interactive.hx", source);
			assertHealthySnapshot(service, source, tail);

			var completion = service.completeResult("Interactive.hx", position);
			if (tail == "f" || tail == "fo" || tail == "foo")
				assertContains(completion.items, "foo", tail);
			if (tail == "foo." || tail == "foo.b" || tail == "foo.ba")
				assertContains(completion.items, "bar", tail);
			if (tail == "foo.bar(" || tail == "foo.bar(x") {
				var signature = service.signatureHelp("Interactive.hx", position);
				if (signature == null || signature.label != "bar(value:Int):Int" || signature.activeParameter != 0)
					throw 'signature help was lost during interactive edit "$tail"';
			}
			if (tail == "foo.bar(x)" && !completion.isIncomplete)
				throw "recovery snapshot unexpectedly became exact without a complete statement";
		}

		var malformed = prefix + "broken.unresolved().member; var after:Foo = foo.";
		service.update("Interactive.hx", malformed);
		assertHealthySnapshot(service, malformed, "malformed statement");
		var malformedSymbols = service.documentSymbols("Interactive.hx");
		if (malformedSymbols.length < 3)
			throw 'malformed statement removed the enclosing function or class symbols: ${[for (symbol in malformedSymbols) symbol.name].join(", ")}';
		assertContains(service.completeResult("Interactive.hx", malformed.length).items, "bar", "after error");

		var diagnostics = service.diagnostics("Interactive.hx"),
			seen:Map<String, Bool> = [];
		for (diagnostic in diagnostics) {
			var key = diagnostic.span.start + ":" + diagnostic.message;
			if (seen.exists(key))
				throw "interactive edit produced duplicate diagnostics";
			seen.set(key, true);
		}

		var boundaryCases:Array<{prefix:String, tails:Array<String>, symbols:Array<String>}> = [
			{
				prefix: "class Foo { public function existing():Void {} }\n",
				tails: ["function test(a:Int,", "class Child extends"],
				symbols: ["Foo", "existing"]
			},
			{
				prefix: "class Foo {}\nfunction main():Void { ",
				tails: [
					"var value:",
					"var value:Foo = new Foo(",
					"if (true) {",
					"new Foo(",
					"var values:Array<Int> = ["
				],
				symbols: ["Foo", "main"]
			}
		];
		for (testCase in boundaryCases)
			for (tail in testCase.tails) {
				var source = testCase.prefix + tail;
				service.update("Interactive.hx", source);
				assertHealthySnapshot(service, source, tail);
				for (name in testCase.symbols)
					assertSymbol(service.documentSymbols("Interactive.hx"), name, tail);
				if (!service.completeResult("Interactive.hx", source.length).isIncomplete)
					throw 'boundary edit "$tail" was not marked as incomplete';
			}

		assertRecoveryEquivalence();

		Sys.println('PASS: ${tails.length + 7} interactive edits retained recovery queries');
	}

	static function assertRecoveryEquivalence():Void {
		var service = new LanguageService(),
			targetSource = "package matrix; class Box { public var member:Int; } function main():Void return;";
		service.update("matrix/Box.hx", targetSource);
		service.compile("matrix.Box");
		var validSource = "package app; import matrix.Box; function helper(value:Box):Box return value; function main():Void { var box:Box = new Box(); box.member; var tail:Box = box; return; }";
		service.update("app/Main.hx", validSource);
		service.compile("app.Main");
		var validState = service.compiler.modules.get("app.Main"),
			validModel = validState.semanticModel,
			validBoxDeclaration = validSource.indexOf("box:Box"),
			validBoxUse = validSource.lastIndexOf("box;"),
			validTailType = validSource.indexOf("tail:Box") + "tail:".length,
			validBoxId = validModel.index.symbolIdAt(validBoxDeclaration),
			validBoxUseId = validModel.index.symbolIdAt(validBoxUse),
			validTypeId = validModel.index.symbolIdAt(validTailType);
		if (validBoxId == null || validBoxUseId == null || validTypeId == null || Std.string(validBoxId) != Std.string(validBoxUseId))
			throw "equivalence fixture did not establish valid local and type identities";

		var malformedSource = "package app; import matrix.Box; function helper(value:Box):Box return value; function main():Void { var box:Box = new Box(); box.member; broken.unresolved().thing; another.unresolved().thing; var tail:Box = box; return; }";
		service.update("app/Main.hx", malformedSource);
		var malformedState = service.compiler.modules.get("app.Main"),
			recoveredModel = malformedState.recoveredSemanticModel,
			malformedBoxDeclaration = malformedSource.indexOf("box:Box"),
			malformedBoxUse = malformedSource.lastIndexOf("box;"),
			malformedTailType = malformedSource.indexOf("tail:Box") + "tail:".length,
			recoveredBoxId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedBoxDeclaration),
			recoveredBoxUseId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedBoxUse),
			recoveredTypeId = recoveredModel == null ? null : recoveredModel.index.symbolIdAt(malformedTailType),
			completion = service.completeResult("app/Main.hx", malformedSource.indexOf("box.member") + "box.".length),
			symbols = service.documentSymbols("app/Main.hx"),
			hasMember = false;
		for (item in completion.items)
			if (item.label == "member")
				hasMember = true;
		if (recoveredModel == null
			|| recoveredBoxId == null
			|| recoveredBoxUseId == null
			|| recoveredTypeId == null
			|| Std.string(recoveredBoxId) != Std.string(validBoxId)
			|| Std.string(recoveredBoxUseId) != Std.string(validBoxUseId)
			|| Std.string(recoveredTypeId) != Std.string(validTypeId)
			|| symbols.length < 2
			|| !hasMember
			|| !completion.isIncomplete)
			throw "recovered snapshot did not preserve unaffected local/type identities and current completion";

		var definition = service.definition("app/Main.hx", malformedBoxUse + 1),
			typeDefinition = service.typeDefinition("app/Main.hx", malformedTailType),
			references = service.references("app/Main.hx", malformedBoxUse + 1),
			currentReference = false;
		for (reference in references)
			if (reference.path == "app/Main.hx" && !reference.stale)
				currentReference = true;
		if (definition == null
			|| definition.stale
			|| definition.span.start != malformedBoxDeclaration
			|| typeDefinition == null
			|| typeDefinition.path != "matrix/Box.hx"
			|| !currentReference)
			throw "recovered navigation did not remain equivalent around an unrelated malformed statement";

		service.update("app/Main.hx", validSource);
		service.compile("app.Main");
		var repairedState = service.compiler.modules.get("app.Main"),
			repairedModel = repairedState.semanticModel,
			repairedBoxId = repairedModel.index.symbolIdAt(validBoxDeclaration),
			repairedBoxUseId = repairedModel.index.symbolIdAt(validBoxUse),
			repairedCompletion = service.completeResult("app/Main.hx", validSource.length);
		if (repairedBoxId == null
			|| repairedBoxUseId == null
			|| Std.string(repairedBoxId) != Std.string(validBoxId)
			|| Std.string(repairedBoxUseId) != Std.string(validBoxUseId)
			|| repairedCompletion.isIncomplete)
			throw "repair did not restore the exact snapshot and stable local identity";
	}

	static function assertHealthySnapshot(service:LanguageService, source:String, tail:String):Void {
		var symbols = service.documentSymbols("Interactive.hx");
		if (symbols.length < 2)
			throw 'interactive edit "$tail" lost structural symbols';
		for (symbol in symbols)
			assertSpan(symbol.span, source.length, "symbol", tail);
		for (diagnostic in service.diagnostics("Interactive.hx"))
			assertSpan(diagnostic.span, source.length, "diagnostic", tail);
		for (token in service.semanticTokens("Interactive.hx"))
			assertSpan(token.span, source.length, "semantic token", tail);
	}

	static function assertContains(items:Array<compiler.service.LanguageService.CompletionItem>, name:String, tail:String):Void {
		for (item in items)
			if (item.label == name)
				return;
		throw 'completion for "$tail" did not contain "$name"';
	}

	static function assertSymbol(symbols:Array<compiler.service.LanguageService.DocumentSymbol>, name:String, tail:String):Void {
		for (symbol in symbols)
			if (symbol.name == name)
				return;
		throw 'edit "$tail" did not retain symbol "$name"';
	}

	static function assertSpan(span:SourceSpan, length:Int, kind:String, tail:String):Void {
		if (span.start < 0 || span.end < span.start || span.end > length)
			throw '$kind span ${span.start}-${span.end} escaped "$tail" source length $length';
	}
}
