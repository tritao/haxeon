import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import tools.LintCommand;
import tools.TypedLint;

/**
 * `haxeon lint --only throw-non-exception` names each `throw` whose value is not statically a haxe.Exception (a String, Dynamic, an
 * enum), through the typed facts the language service's analysis records, and not a throw of an exception or a subclass. The rule is
 * opt-in, like `unbound-local`, and has no fix.
 */
class LintThrowNonExceptionMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-throw-non-exception-" + Std.random(0x7fffffff)]);
		FileSystem.createDirectory(Path.join([base, "app/src/app"]));
		write(base, "app/haxeon.json",
			'{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"]}');
		write(base, "app/src/app/Main.hx", [
			'package app;',
			'',
			'import haxe.Exception;',
			'',
			'class Failure extends Exception {}',
			'',
			'function main() {',
			'	try {',
			'		if (Sys.args().length > 3)',
			'			throw "text";',
			'		if (Sys.args().length > 2)',
			'			throw new Failure("failure");',
			'		var n = Sys.args().length > 1 ? 1 : throw 7;',
			'	} catch (e:Dynamic) {',
			'		throw e;',
			'	}',
			'	throw new Exception("done");',
			'}',
			''
		].join("\n"));
		var mainPath = Path.join([base, "app/src/app/Main.hx"]);

		var report = TypedLint.find("throw-non-exception", [mainPath], "/");
		function thrown(line:Int, type:String):String
			return '$mainPath:$line: throw of $type, not a haxe.Exception: throw an Exception subclass';
		expect("Main.hx", report.lines, [thrown(10, "String"), thrown(13, "Int"), thrown(15, "Dynamic")]);
		if (report.failed)
			throw "Main.hx types, but the rule says it failed";

		// The option: off by default, run through the typed-rule tool only when `--only throw-non-exception` names it.
		var ran:Null<String> = null;
		function typedRules(rule:String, files:Array<String>):Int {
			ran = rule;
			return 1;
		}
		var status = LintCommand.run([mainPath], null, typedRules);
		if (ran != null || status != 0)
			throw 'A plain lint ran the opt-in rule (status $status)';
		status = LintCommand.run(["--only", "throw-non-exception", mainPath], null, typedRules);
		if (status != 1 || ran != "throw-non-exception")
			throw '--only throw-non-exception did not run the rule (status $status, ran $ran)';
		expectThrows(() -> LintCommand.run(["--fix", "--only", "throw-non-exception", mainPath], null, typedRules),
			"has no fix");
		Sys.println("PASS: haxeon lint --only throw-non-exception names the throws of a value that is not a haxe.Exception");
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

	static function write(base:String, path:String, content:String):Void {
		var full = Path.join([base, path]);
		FileSystem.createDirectory(Path.directory(full));
		File.saveContent(full, content);
	}
}
