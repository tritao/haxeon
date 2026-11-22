import compiler.CompileOptions;
import compiler.Compiler;
import compiler.NullSafetyRule;
import compiler.core.Diagnostic;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/**
 * The null-safety checker (`@:nullSafety`, docs/reference/LANGUAGE_SUPPORT.md, "Null safety") reports what stock Haxe 4.3.7
 * reports, at the same lines and columns: the fixtures are Haxe's own probes, and each expectation below is Haxe's output for
 * them in that mode, but where a comment says how Haxeon differs. Off by default, set per class, field, expression and by rule.
 */
class NullSafetyMain {
	static final FIXTURES = "tests/fixtures/null-safety/";

	static function main():Void {
		var probe = File.getContent(FIXTURES + "Probe.hx");
		// What every mode reports of the probe; it checks before reading `l.length` where Haxe's probe used `?.`.
		var common = [
			"16:10 Cannot use \"this\" until all instance fields are initialized.",
			"20:45 Cannot return nullable value of Null<String> as String",
			"23:3 Cannot assign nullable value here.",
			"24:7 Cannot pass nullable value to not-nullable argument \"s\" of function \"arg\".",
			"32:19 Cannot cast nullable value to not nullable type.",
			"34:15 Cannot pass nullable value to not-nullable argument \"s\" of function \"take\".",
			"37:13 Cannot access \"length\" of a nullable value.",
			"42:3 Cannot assign nullable value here.",
			"44:3 Cannot assign nullable value here.",
			"46:3 Cannot call a nullable value."
		];
		// A closure Strict checks may run later, so it trusts no narrowing of a local it captures.
		var closure = "50:23 Cannot pass nullable value to not-nullable argument \"s\" of function \"arg\".";
		expectFindings("the probe, Loose", mode(probe, "Loose"), common);
		expectFindings("the probe, Strict", mode(probe, "Strict"), common.concat([closure]));
		// StrictThreaded narrows no field that is not final: `if (o.c != null) arg(o.c)` is reported.
		expectFindings("the probe, StrictThreaded", mode(probe, "StrictThreaded"),
			common.concat([
				closure,
				"40:24 Cannot pass nullable value to not-nullable argument \"s\" of function \"arg\"."
			]));

		var narrowing = File.getContent(FIXTURES + "Narrowing.hx");
		// Loose trusts a field's narrowing across a call, as Haxe's does; Strict does not; StrictThreaded narrows no field at all.
		expectFindings("field narrowing, Loose", mode(narrowing, "Loose"), []);
		expectFindings("field narrowing, Strict", mode(narrowing, "Strict"),
			["9:10 Cannot access \"length\" of a nullable value."]);
		expectFindings("field narrowing, StrictThreaded", mode(narrowing, "StrictThreaded"),
			["9:10 Cannot access \"length\" of a nullable value.",
			"12:9 Cannot access \"length\" of a nullable value."]);

		expectFindings("fields, constructors and conversions", File.getContent(FIXTURES + "Initialization.hx"), [
			"15:3 Cannot call method helper until all instance fields are initialized.",
			"17:11 Cannot use field b until initialization.",
			"11:2 Field \"neverSet\" is not nullable thus should have an initial value or should be initialized in constructor.",
			"12:2 Field \"opt\" is not nullable thus should have an initial value or should be initialized in constructor.",
			"24:2 Field \"st\" is not nullable thus should have an initial value.",
			"29:3 Cannot assign nullable value here.",
			"30:28 Cannot use nullable value of String as an item in Array<String>",
			"32:3 Cannot unify Array<Null<String>> with Array<String>",
			// Haxe points at the declaration (33:3); Haxeon at the field of the literal that is null.
			"33:26 Cannot assign nullable value here.",
			"36:3 Cannot unify (String)->Void with (Null<String>)->Void",
			"37:3 Cannot assign nullable value here.",
			"39:3 Cannot assign nullable value here.",
			// Haxe points at the declaration (lines 41-44); Haxeon at the switch's branch that is null.
			"42:15 Cannot assign nullable value here.",
			"52:4 Cannot assign nullable value here."
		]);
		expectFindings("generic functions", File.getContent(FIXTURES + "Generics.hx"), []);
		expectFindings("an enum constructor's argument, and an optional one",
			"enum E { A(value:String, ?other:String); }\n"
			+ "@:nullSafety(Strict) class Main { static function main() { var s:Null<String> = null; var e = A(s, s); } }",
			["2:97 Cannot pass nullable value to not-nullable argument \"value\" of function \"A\"."]);

		// Off unless something turns it on, as in Haxe.
		var unchecked = "class Main { static function main() { var s:String = null; trace(s); } }";
		expectFindings("no metadata, no rule", unchecked, []);
		// Off on a field, an expression or a statement.
		expectFindings(
			"Off on a field, an expression and a statement",
			"@:nullSafety(Strict) class Main { @:nullSafety(Off) static function f() { var s:String = null; }\n"
				+ "static function main() { var t:String = @:nullSafety(Off) (null : Null<String>);\n"
				+ "@:nullSafety(Off) var u:String = null; var v:String = null; } }",
			// The Off expression is not checked, but its value is still a Null<String> where the local takes it, as in Haxe.
			["2:26 Cannot assign nullable value here.", "3:40 Cannot assign nullable value here."]
		);
		expectFindings("an argument Haxe does not take", "@:nullSafety(Yes) class Main { static function main() {} }",
			["1:1 Invalid argument for @:nullSafety meta"]);

		// A rule is Haxe's `--macro nullSafety(path, mode, recursive)`, with metadata applied after it.
		expectFindings("a rule on the module", unchecked, ["1:39 Cannot assign nullable value here."],
			[new NullSafetyRule("Main", Strict)]);
		expectFindings("a rule on another package", unchecked, [], [new NullSafetyRule("other", Strict)]);
		// A module-level function is a static of its module's class, as in Haxe.
		var moduleLevel = "function main():Void { var s:String = null; }";
		expectFindings("a rule on a module-level function", moduleLevel, ["1:24 Cannot assign nullable value here."],
			[new NullSafetyRule("Main", Strict)]);
		expectFindings("metadata on a module-level function", "@:nullSafety(Strict) " + moduleLevel,
			["1:45 Cannot assign nullable value here."]);
		expectFindings("Off metadata under a rule", "@:nullSafety(Off) " + unchecked, [],
			[new NullSafetyRule("", Strict)]);
		// Loose cannot lower Strict: a call still forgets the field's narrowing.
		expectFindings("Loose metadata under a Strict rule", StringTools.replace(narrowing, "@:nullSafety(MODE)",
			"@:nullSafety(Loose)"), ["9:10 Cannot access \"length\" of a nullable value."],
			[new NullSafetyRule("", Strict)]);
		// `warn` reports Strict's findings as warnings, and the program builds.
		var warned = compile(unchecked, [new NullSafetyRule("Main", Warn)]);
		if (warned.failed || warned.diagnostics.length != 1 || warned.diagnostics[0].code != "W1003"
			|| !warned.diagnostics[0].severity.match(Warning))
			throw 'a warn rule should build with one W1003 warning, got ${describe(warned.diagnostics)}';
		// A rebuild that does not type a checked class's constructor again leaves its fields as that constructor set them: what
		// it has of the constructor is its signature alone.
		var session = new Compiler(null, CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.update("Box.hx",
			"@:nullSafety(Strict) class Box { public final name:String; public function new() { name = \"a\"; } }");
		session.update("Main.hx", "class Main { static function main() { trace(new Box().name); } }");
		session.compile("Main");
		session.update("Main.hx", "class Main { static function main() { trace(new Box().name + 1); } }");
		try {
			var rebuilt = session.compile("Main");
			if (rebuilt.retyped.indexOf("Box.new") >= 0)
				throw 'Box.new was typed again, so this does not test a rebuild without it: ${rebuilt.retyped}';
		} catch (error:CompileError) {
			throw 'a rebuild that kept Box.new reported ${describe(error.diagnostics)}';
		}
		Sys.println("PASS: null safety reports what Haxe reports, per mode, metadata and rule");
	}

	static function mode(source:String, mode:String):String
		return StringTools.replace(StringTools.replace(source, "@:nullSafety(Strict)", '@:nullSafety($mode)'),
			"@:nullSafety(MODE)", '@:nullSafety($mode)');

	static function compile(source:String, ?rules:Array<NullSafetyRule>):{failed:Bool, diagnostics:Array<Diagnostic>} {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		if (rules != null)
			compiler.options = new CompileOptions({nullSafety: rules});
		compiler.update("Main.hx", source);
		try {
			var result = compiler.compile("Main");
			return {failed: false, diagnostics: compiler.warnings(result.moduleNames)};
		} catch (error:CompileError) {
			return {failed: true, diagnostics: error.diagnostics};
		}
	}

	/** The null-safety findings of compiling `source`, each as Haxe prints it: `line:column message`, without "Null safety: ". */
	static function expectFindings(label:String, source:String, expected:Array<String>,
			?rules:Array<NullSafetyRule>):Void {
		var result = compile(source, rules), found:Array<String> = [];
		for (diagnostic in result.diagnostics) {
			if (diagnostic.code != "E1005" || !StringTools.startsWith(diagnostic.message, "Null safety: "))
				throw '$label: unexpected ${diagnostic.format()}';
			var location = diagnostic.span.file.lineColumnAt(diagnostic.span.start);
			found.push('${location.line}:${location.column} ${diagnostic.message.substr("Null safety: ".length)}');
		}
		var missing = [for (item in expected) if (found.indexOf(item) < 0) item],
			extra = [for (item in found) if (expected.indexOf(item) < 0) item];
		if (missing.length > 0 || extra.length > 0)
			throw '$label: missing [${missing.join("; ")}], unexpected [${extra.join("; ")}]';
		if (result.failed != (expected.length > 0))
			throw '$label: the compile ${result.failed ? "failed" : "succeeded"} with ${describe(result.diagnostics)}';
	}

	static function describe(diagnostics:Array<Diagnostic>):String
		return '[' + [for (diagnostic in diagnostics) diagnostic.format()].join("; ") + ']';
}
