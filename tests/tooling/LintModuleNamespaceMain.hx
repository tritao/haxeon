import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import tools.LintCommand;
import tools.TypedLint;

/**
 * `haxeon lint --only module-namespace` names each module-level variable or function reached through its module's name
 * (`Settings.hits` with `import app.Settings`), a Haxeon extension Haxe rejects. Haxe's forms are not named: an imported member, the
 * full path, and a class's own static named through the imported class, which wins over a module variable of the same name. The rule
 * is opt-in, like `unbound-local`.
 */
class LintModuleNamespaceMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-module-namespace-" + Std.random(0x7fffffff)]);
		FileSystem.createDirectory(Path.join([base, "app/src/app"]));
		write(base, "app/haxeon.json",
			'{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"]}');
		write(base, "app/src/app/Settings.hx", [
			'package app;',
			'',
			'var hits = 0;',
			'',
			'function record():Void',
			'	hits++;',
			''
		].join("\n"));
		write(base, "app/src/app/Store.hx", [
			'package app;',
			'',
			'var count = 1;',
			'',
			'class Store {',
			'	public static var count = 2;',
			'}',
			''
		].join("\n"));
		write(base, "app/src/app/Main.hx", [
			'package app;',
			'',
			'import app.Settings;',
			'import app.Settings.hits;',
			'import app.Store;',
			'',
			'function main() {',
			'	Settings.record();',
			'	Settings.hits = 5;',
			'	trace(Settings.hits);',
			'	var recorded = Settings.record;',
			'	trace(hits + app.Settings.hits + Store.count + app.Store.count);',
			'}',
			''
		].join("\n"));
		var mainPath = Path.join([base, "app/src/app/Main.hx"]);

		var report = TypedLint.find("module-namespace", [mainPath], "/");
		function use(line:Int, written:String, member:String):String
			return '$mainPath:$line: "$written" names $member through its module\'s name, which Haxe rejects: '
				+ 'import $member or write it in full';
		expect("Main.hx", report.lines, [
			use(8, "Settings.record", "app.Settings.record"),
			use(9, "Settings.hits", "app.Settings.hits"),
			use(10, "Settings.hits", "app.Settings.hits"),
			use(11, "Settings.record", "app.Settings.record")
		]);
		if (report.failed)
			throw "Main.hx types, but the rule says it failed";

		// The option: off by default, run through the typed-rule tool only when `--only module-namespace` names it.
		var ran:Null<String> = null;
		function typedRules(rule:String, files:Array<String>):Int {
			ran = rule;
			return 1;
		}
		var status = LintCommand.run([mainPath], null, typedRules);
		if (ran != null || status != 0)
			throw 'A plain lint ran the opt-in rule (status $status)';
		status = LintCommand.run(["--only", "module-namespace", mainPath], null, typedRules);
		if (status != 1 || ran != "module-namespace")
			throw '--only module-namespace did not run the rule (status $status, ran $ran)';
		expectThrows(() -> LintCommand.run(["--fix", "--only", "module-namespace", mainPath], null, typedRules),
			"has no fix");
		Sys.println("PASS: haxeon lint --only module-namespace names module members reached through their module's name");
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
