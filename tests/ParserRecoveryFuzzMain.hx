import compiler.Source.SourceSpan;
import compiler.Diagnostic.CompileError;
import compiler.service.LanguageService;

class ParserRecoveryFuzzMain {
	static inline final CASES = 72;
	static inline final MAX_CASE_MS = 500.0;

	static function main():Void {
		var source = "class Box { public var value:Int; public function read(scale:Int):Int { if (scale > 0) return value * scale; return 0; } } function helper(value:Int):Int return value; function main():Int { var box:Box = new Box(); var values = [1, 2]; var callback = (item:Int) -> item + 1; box.value; return switch (values[0]) { case 1: callback(helper(41)); default: box.read(1); }; }",
			service = new LanguageService();
		service.update("Main.hx", source);
		service.analyze("Main");
		var fragments = [";", ")", "}", ",", ".", ":", "=", "(", "[", "?"], totalMs = 0.0, maxMs = 0.0;
		for (caseIndex in 0...CASES) {
			var position = (caseIndex * 37 + 11) % source.length,
				width = 1 + caseIndex % 3,
				end = Std.int(Math.min(source.length, position + width)),
				mutated = switch caseIndex % 3 {
					case 0: source.substring(0, position) + source.substring(end);
					case 1: source.substring(0, position) + fragments[caseIndex % fragments.length] + source.substring(position);
					default: source.substring(0, position) + fragments[caseIndex % fragments.length] + source.substring(end);
				}, started = Sys.time();
			service.update("Main.hx", mutated);
			try
				service.analyze("Main")
			catch (_:CompileError) {}
			assertQueries(service, mutated, caseIndex);
			var elapsed = (Sys.time() - started) * 1000.0;
			totalMs += elapsed;
			if (elapsed > maxMs)
				maxMs = elapsed;
			if (elapsed > MAX_CASE_MS)
				throw 'recovery mutation $caseIndex exceeded ${MAX_CASE_MS}ms: ${elapsed}ms';
		}
		service.update("Main.hx", source);
		service.analyze("Main");
		if (service.diagnostics("Main.hx").length != 0 || service.documentSymbols("Main.hx").length == 0)
			throw "restoring valid source did not clear recovery state";
		for (symbol in service.documentSymbols("Main.hx"))
			if (symbol.stale)
				throw "restored valid source retained stale symbols";
		Sys.println('PASS: $CASES deterministic recovery mutations averaged ${totalMs / CASES}ms, max ${maxMs}ms');
	}

	static function assertQueries(service:LanguageService, source:String, caseIndex:Int):Void {
		var length = source.length, diagnostics = service.diagnostics("Main.hx");
		if (diagnostics.length > 20)
			throw 'mutation $caseIndex exceeded the diagnostic budget';
		for (diagnostic in diagnostics)
			assertSpan(diagnostic.span, length, "diagnostic", caseIndex);
		for (symbol in service.documentSymbols("Main.hx"))
			assertSpan(symbol.span, length, "document symbol", caseIndex);
		for (token in service.semanticTokens("Main.hx"))
			assertSpan(token.span, length, "semantic token", caseIndex);
		for (fold in service.foldingRanges("Main.hx"))
			assertSpan(fold.span, length, "fold", caseIndex);
		for (ranges in service.selectionRanges("Main.hx", [Std.int(Math.min(length, length == 0 ? 0 : (caseIndex * 13) % length))]))
			for (range in ranges)
				assertSpan(range, length, "selection", caseIndex);
		service.complete("Main.hx", length);
		service.hover("Main.hx", length);
		var probe = source.lastIndexOf("box");
		if (probe < 0)
			return;
		var definition = service.definition("Main.hx", probe + 1);
		if (definition != null)
			assertSpan(definition.span, length, "definition", caseIndex);
		for (reference in service.references("Main.hx", probe + 1))
			assertSpan(reference.span, length, "reference", caseIndex);
		for (edit in service.rename("Main.hx", probe + 1, "renamed"))
			assertSpan(edit.span, length, "rename", caseIndex);
		for (highlight in service.documentHighlights("Main.hx", probe + 1))
			assertSpan(highlight.span, length, "highlight", caseIndex);
	}

	static function assertSpan(span:SourceSpan, length:Int, kind:String, caseIndex:Int):Void {
		if (span.start < 0 || span.end < span.start || span.end > length)
			throw '$kind span ${span.start}-${span.end} is outside mutation $caseIndex length $length';
	}
}
