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

		Sys.println('PASS: ${tails.length} interactive edits retained recovery queries');
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

	static function assertSpan(span:SourceSpan, length:Int, kind:String, tail:String):Void {
		if (span.start < 0 || span.end < span.start || span.end > length)
			throw '$kind span ${span.start}-${span.end} escaped "$tail" source length $length';
	}
}
