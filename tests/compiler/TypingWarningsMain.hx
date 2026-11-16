import compiler.Compiler;
import compiler.core.Diagnostic;
import compiler.runtime.CompilerIntrinsics;
import compiler.service.LanguageService;

/**
 * W1001: a nullable number read as a plain one warns, since null silently becomes the default. Warnings are kept with the
 * body that raised them, so an incremental compile that reuses the body keeps them and one that deletes it drops them.
 */
class TypingWarningsMain {
	static final quiet = "function other():Int { return 1; }";

	static function main():Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.update("Main.hx", source("var m = [\"a\" => 40]; return m.get(\"a\") + other();", quiet));
		var warnings = compile(compiler);
		if (warnings.length != 1 || warnings[0].code != "W1001" || !warnings[0].severity.match(Warning))
			throw 'expected one W1001 warning, got ${describe(warnings)}';
		var fix = warnings[0].fixes.length == 1 ? warnings[0].fixes[0] : null;
		if (fix == null || fix.edits.length != 1 || fix.edits[0].replacement != '(m.get("a") ?? 0)')
			throw 'W1001 should offer to write the default out, got ${fix == null ? "no fix" : fix.edits[0].replacement}';

		// Another function's body changes; the warned one is reused, not typed again, and keeps its warning.
		compiler.update("Main.hx",
			source("var m = [\"a\" => 40]; return m.get(\"a\") + other();", "function other():Int { return 2; }"));
		var reuse = compiler.compile("Main");
		if (reuse.retyped.indexOf("main") >= 0)
			throw 'main was typed again, so this does not test reuse: ${reuse.retyped}';
		warnings = compiler.warnings(reuse.moduleNames);
		if (warnings.length != 1)
			throw 'a reused body lost its warning: ${describe(warnings)}';

		// Writing the default out is what the warning asks for, and silences it.
		compiler.update("Main.hx", source("var m = [\"a\" => 40]; return (m.get(\"a\") ?? 0) + other();", quiet));
		warnings = compile(compiler);
		if (warnings.length != 0)
			throw 'an explicit default still warned: ${describe(warnings)}';

		// Explicit checks and joins that keep the null do not warn.
		compiler.update("Main.hx",
			source("var xs = [1]; var top = xs.pop(); if (top == null) return 0; var kept = true ? xs.pop() : 5; return top + other() + (kept == null ? 0 : 1);",
			quiet));
		warnings = compile(compiler);
		if (warnings.length != 0)
			throw 'checked values warned: ${describe(warnings)}';

		// A warned function that is deleted takes its warning with it.
		compiler.update("Main.hx",
			"function helper():Int { var m = [\"a\" => 1]; return m.get(\"a\"); } function main():Int return helper();");
		if (compile(compiler).length != 1)
			throw "the helper's warning was not reported";
		compiler.update("Main.hx", "function main():Int return 42;");
		warnings = compile(compiler);
		if (warnings.length != 0)
			throw 'a deleted function kept its warning: ${describe(warnings)}';

		// The language service publishes the same warnings with the document's diagnostics.
		var service = new LanguageService();
		service.update("Main.hx", source("var m = [\"a\" => 40]; return m.get(\"a\") + other();", quiet));
		service.analyze("Main");
		var published = [
			for (diagnostic in service.diagnostics("Main.hx"))
				if (diagnostic.code == "W1001") diagnostic
		];
		if (published.length != 1 || !published[0].severity.match(Warning))
			throw 'the language service did not publish the warning: ${describe(service.diagnostics("Main.hx"))}';
		Sys.println("PASS: typing warnings survive reuse, leave with their body, and reach the language service");
	}

	static function source(mainBody:String, rest:String):String
		return 'function main():Int { $mainBody } $rest';

	static function compile(compiler:Compiler):Array<Diagnostic>
		return compiler.warnings(compiler.compile("Main").moduleNames);

	static function describe(diagnostics:Array<Diagnostic>):String
		return '[' + [for (diagnostic in diagnostics) diagnostic.format()].join("; ") + ']';
}
