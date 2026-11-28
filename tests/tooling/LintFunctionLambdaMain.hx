import haxe.io.Path;
import haxeon.io.FileTree;
import sys.FileSystem;
import sys.io.File;
import tools.LintCommand;
import tools.TypedLint;

/**
 * `haxeon lint` reports a lambda written `function(...)` that an arrow can write (rule `function-lambda`), and `--fix` writes it
 * as one where the two mean the same. Syntax shows that for an expression body (an opening `return` dropped) and for a block that
 * does not end in an expression. A block that does is converted only when the typer saw that changes nothing in every typing of
 * it, since an arrow returns the value a `function` drops: its type returns Void, or the value is Void. A lambda stored with no type,
 * or passed for a type variable, whose last value is not Void keeps its form and stays reported. A return type, a named local function and a file's `// @lint:off function-lambda` are left alone.
 */
class LintFunctionLambdaMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-function-lambda-" + Std.random(0x7fffffff)]);
		FileSystem.createDirectory(Path.join([base, "app/src/app"]));
		File.saveContent(Path.join([base, "app/haxeon.json"]),
			'{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"]}');
		var path = Path.join([base, "app/src/app/Main.hx"]);
		function source(lines:Array<String>):String
			return [
				"package app;",
				"",
				"function apply(f:Int->Int):Int return f(1);",
				"function each(f:Int->Void):Void f(2);",
				"function keep<T>(f:Void->T):Void f();",
				"",
				"function main() {",
				"\tvar list = [0];"
			].concat(lines)
				.concat(["\tstored(); named(5);", "}", ""]).join("\n");
		var kept = [
			"\tvar stored = function() { list.push(3); };",
			"\tkeep(function() { list.push(4); });",
			"\tapply(function(x):Int return x);",
			"\tfunction named(x:Int) { list.push(x); }"
		];
		File.saveContent(path, source([
			"\tapply(function(x) return x + 1);",
			"\tapply(function(x:Int) { return x; });",
			"\teach(function(x) { list.push(x); });",
			"\teach(function(_) {});",
			"\tvar quiet = function() { each(_ -> {}); };"
		].concat(kept)));
		if (LintCommand.run(["--only", "function-lambda", path]) != 1)
			throw "lint did not report the function lambdas";
		var typedRules = (rule:String, files:Array<String>) -> TypedLint.run(rule, files, "/");
		if (LintCommand.run(["--fix", path], null, typedRules) != 0)
			throw "lint --fix failed";
		var wanted = source([
			"\tapply(x -> x + 1);",
			"\tapply((x:Int) -> { return x; });",
			"\teach(x -> { list.push(x); });",
			"\teach(_ -> {});",
			"\tvar quiet = () -> { each(_ -> {}); };"
		].concat(kept));
		var fixed = File.getContent(path);
		if (fixed != wanted)
			throw 'lint --fix wrote:\n$fixed';
		// The two whose type does not return Void stay reported.
		if (LintCommand.run(["--only", "function-lambda", path]) != 1)
			throw "lint no longer reports the lambdas an arrow would change";
		File.saveContent(path, fixed + "// @lint:off function-lambda\n");
		if (LintCommand.run(["--only", "function-lambda", path]) != 0)
			throw "@lint:off function-lambda did not turn the rule off";
		FileTree.remove(base);
		Sys.println("PASS: lint writes a function lambda as an arrow where the two mean the same, and reports the rest");
	}
}
