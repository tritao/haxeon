import haxe.io.Path;
import haxeon.io.FileTree;
import sys.FileSystem;
import sys.io.File;
import tools.LintCommand;
import tools.TypedLint;

/**
 * `haxeon lint --only unbound-local` names each local whose type nothing fixes, which settles to Dynamic, typing the file's project
 * through the language service. The rule is opt-in: a plain `haxeon lint` neither runs it nor needs types. A local fixed later is
 * not named, nor is a local of a body that fails to type, while the bodies that type are still reported. A project's file outside
 * its source roots resolves the modules beside it.
 */
class LintUnboundLocalMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-unbound-local-" + Std.random(0x7fffffff)]);
		FileSystem.createDirectory(Path.join([base, "app/src/app"]));
		write(base, "app/haxeon.json",
			'{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"]}');
		write(base, "app/src/app/Main.hx", [
			'package app;',
			'',
			'function unassigned():Int {',
			'	var never;',
			'	return 1;',
			'}',
			'',
			'function empty():Int {',
			'	var items = [];',
			'	return 1;',
			'}',
			'',
			'function fixedLater():Int {',
			'	var later;',
			'	later = 2;',
			'	var pushed = [];',
			'	pushed.push(1);',
			'	return later + pushed[0];',
			'}',
			'',
			'function main() {',
			'	trace(unassigned() + empty() + fixedLater() + app.Other.used());',
			'}',
			''
		].join("\n"));
		write(base, "app/src/app/Other.hx", [
			'package app;',
			'',
			'class Other {',
			'	public static function used():Int {',
			'		var unused;',
			'		return 1;',
			'	}',
			'}',
			''
		].join("\n"));
		write(base, "app/src/app/Broken.hx", [
			'package app;',
			'',
			'function fine():Int {',
			'	var stillReported;',
			'	return 1;',
			'}',
			'',
			'function broken():Int {',
			'	var inFailedBody;',
			'	var wrong:String = 1;',
			'	return 1;',
			'}',
			''
		].join("\n"));
		var mainPath = Path.join([base, "app/src/app/Main.hx"]),
			otherPath = Path.join([base, "app/src/app/Other.hx"]),
			brokenPath = Path.join([base, "app/src/app/Broken.hx"]);

		// Each local named once, at its declaration; Other.hx is typed as Main's dependency and reported only when listed.
		var report = TypedLint.find("unbound-local", [mainPath], "/");
		expect("Main.hx", report.lines, [
			'$mainPath:4: local "never" is Dynamic: nothing fixes the type of local "never"',
			'$mainPath:9: local "items" is Dynamic: nothing fixes the element type of this empty array'
		]);
		if (report.failed)
			throw "Main.hx types, but the rule says it failed";
		report = TypedLint.find("unbound-local", [mainPath, otherPath], "/");
		if (report.lines.length != 3
			|| report.lines[2] != '$otherPath:5: local "unused" is Dynamic: nothing fixes the type of local "unused"')
			throw 'Other.hx: unexpected report:\n${report.lines.join("\n")}';
		// A relative path is resolved against the base and printed as given.
		report = TypedLint.find("unbound-local", ["app/src/app/Other.hx"], base);
		expect("relative path", report.lines,
			['app/src/app/Other.hx:5: local "unused" is Dynamic: nothing fixes the type of local "unused"']);

		// A body that fails is not reported; the bodies that type still are, and the run fails.
		report = TypedLint.find("unbound-local", [brokenPath], "/");
		expect("Broken.hx", report.lines,
			['$brokenPath:4: local "stillReported" is Dynamic: nothing fixes the type of local "stillReported"']);
		if (!report.failed)
			throw "Broken.hx does not type, but the rule did not say so";

		// A project's file outside its source roots (a test beside src) is typed with the root its package implies, so the
		// modules beside it resolve.
		FileSystem.createDirectory(Path.join([base, "app/tests"]));
		write(base, "app/tests/AppTest.hx", [
			'function main() {',
			'	var loose;',
			'	trace(TestHelper.value());',
			'}',
			''
		].join("\n"));
		write(base, "app/tests/TestHelper.hx",
			'class TestHelper {\n\tpublic static function value():Int\n\t\treturn 1;\n}\n');
		var testPath = Path.join([base, "app/tests/AppTest.hx"]);
		report = TypedLint.find("unbound-local", [testPath], "/");
		expect("AppTest.hx", report.lines,
			['$testPath:2: local "loose" is Dynamic: nothing fixes the type of local "loose"']);
		if (report.failed)
			throw "AppTest.hx types with the module beside it, but the rule says it failed";

		// The option: off by default, run through the typed-rule tool only when `--only unbound-local` names it.
		var ran:Null<Array<String>> = null;
		function typedRules(rule:String, files:Array<String>):Int {
			ran = rule == "unbound-local" ? files : null;
			return 1;
		}
		var status = LintCommand.run([mainPath], null, typedRules);
		if (ran != null || status != 0)
			throw 'A plain lint ran the opt-in rule (status $status)';
		status = LintCommand.run(["--only", "unbound-local", Path.join([base, "app/src/app"])], null, typedRules);
		if (status != 1 || ran == null || ran.length != 3)
			throw '--only unbound-local did not run the rule on the directory\'s files (status $status)';
		expectThrows(() -> LintCommand.run(["--fix", "--only", "unbound-local", mainPath], null, typedRules),
			"has no fix");
		expectThrows(() -> LintCommand.run(["--only", "unbound-local", mainPath]), "needs the typed lint tool");
		expectThrows(() -> LintCommand.run(["--only", "nothing", mainPath]), "unbound-local");
		FileTree.remove(base);
		Sys.println("PASS: lint names the locals that settle to Dynamic, only when asked, and none of a failed body");
	}

	static function expect(label:String, actual:Array<String>, expected:Array<String>):Void
		if (actual.join("\n") != expected.join("\n"))
			throw '$label: expected\n${expected.join("\n")}\ngot\n${actual.join("\n")}';

	static function expectThrows(action:() -> Int, fragment:String):Void {
		var message:Null<String> = null;
		try
			action()
		catch (error:Dynamic)
			message = Std.string(error);
		if (message == null || message.indexOf(fragment) < 0)
			throw 'Expected an error mentioning "$fragment", got ${message == null ? "none" : message}';
	}

	static function write(base:String, relative:String, text:String):Void
		File.saveContent(Path.join([base, relative]), text);
}
