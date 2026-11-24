#!/usr/bin/env haxeon
/**
 * `haxeon script.hx` (tools.ScriptRun): a script builds quietly and runs with its arguments, its exit status, a dashed file name, the caller's
 * working directory and the modules beside it; a sibling that does not compile is not built; a compile error goes to
 * standard error and fails the run; a script in a package's folders traces the package path; and, outside Windows, a `#!/usr/bin/env haxeon` script runs as a program.
 */
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;
import sys.io.File;

function main() {
	var work = Path.join([Path.directory(Path.directory(Script.directory())), "out", "test-haxeon-script"]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	FileSystem.createDirectory(Path.join([work, "caller"]));
	// Scripts get a cache of their own, so this test never reuses or disturbs the user's.
	var env = ["HAXEON_SCRIPT_CACHE" => Path.join([work, "cache"])];
	File.saveContent(Path.join([work, "say-hello.hx"]),
		"#!/usr/bin/env haxeon\nfunction main():Int {\n\tSys.println(\"hello \" + Sys.args().join(\",\") + \" \" + Helper.twice(21) + \" \" + sys.io.File.getContent(\"note.txt\"));\n\treturn Sys.args().length;\n}\n");
	File.saveContent(Path.join([work, "Helper.hx"]),
		"class Helper {\n\tpublic static function twice(n:Int):Int return n * 2;\n}\n");
	File.saveContent(Path.join([work, "broken.hx"]), "function main() { this does not compile }\n");
	File.saveContent(Path.join([work, "mistyped.hx"]), "function main() {\n\tvar x:Int = \"text\";\n}\n");
	File.saveContent(Path.join([work, "caller", "note.txt"]), "from-the-caller");

	var log = Path.join([work, "greet.log"]),
		status = Script.run(Script.haxeon(), ["../say-hello.hx", "a", "b"], {
			cwd: Path.join([work, "caller"]),
			env: env,
			log: log
		}),
		output = File.getContent(log);
	if (status != 2 || output != "hello a,b 42 from-the-caller\n")
		Script.fail('FAIL: the script printed ${haxe.Json.stringify(output)} and exited with $status, expected only its line and 2');

	var mistyped = Path.join([work, "mistyped.log"]);
	status = Script.run(Script.haxeon(), [Path.join([work, "mistyped.hx"])], {env: env, log: mistyped});
	if (status == 0 || File.getContent(mistyped).indexOf("mistyped.hx:2:") < 0)
		Script.fail('FAIL: a script that does not compile exited with $status; its log:\n${File.getContent(mistyped)}');

	checkTopLevelStatements(work, env);

	// A script that declares a package and lives in its folders is rooted where the package starts, as a project is, so its
	// positions carry the package path.
	FileSystem.createDirectory(Path.join([work, "tool", "b"]));
	File.saveContent(Path.join([work, "tool", "b", "Main.hx"]),
		"package b;\n\nfunction main() {\n\ttrace(\"traced\");\n}\n");
	var packaged = Path.join([work, "packaged.log"]);
	status = Script.run(Script.haxeon(), [Path.join([work, "tool", "b", "Main.hx"])], {env: env, log: packaged});
	if (status != 0 || File.getContent(packaged) != "b/Main.hx:4: traced\n")
		Script.fail('FAIL: a script in package b printed ${haxe.Json.stringify(File.getContent(packaged))} and exited with $status, expected its trace at b/Main.hx');

	if (Sys.systemName() != "Windows") {
		Script.check("chmod", ["+x", Path.join([work, "say-hello.hx"])]);
		var path = Path.directory(Script.haxeon()) + ":" + Sys.getEnv("PATH"),
			directLog = Path.join([work, "direct.log"]),
			directStatus = Script.run(Path.join([work, "say-hello.hx"]), ["direct"], {
				cwd: Path.join([work, "caller"]),
				env: ["HAXEON_SCRIPT_CACHE" => env["HAXEON_SCRIPT_CACHE"], "PATH" => path],
				log: directLog
			}),
			direct = File.getContent(directLog);
		if (directStatus != 1 || direct != "hello direct 42 from-the-caller\n")
			Script.fail('FAIL: running the script through its #! line printed ${haxe.Json.stringify(direct)} and exited with $directStatus');
	}
	Sys.println("PASS: a script runs with its arguments, status, caller's directory and neighbours; a compile error fails it quietly");
}

function checkTopLevelStatements(work:String, env:Map<String, String>):Void {
	var source = Path.join([work, "Statements.hx"]),
		log = Path.join([work, "statements.log"]);
	File.saveContent(source,
		'#!/usr/bin/env haxeon
import haxe.io.Path;

final who = Sys.args().join(",");
var count = 0, multiplier = 2;
for (i in 0...2)
	count += i;
Sys.println(greet(who) + " " + Later.multiply(count, multiplier));
trace("traced");

function greet(name:String):String
	return "hello " + Path.withoutExtension(name);

class Later {
	public static function multiply(n:Int, multiplier:Int):Int return n * multiplier;
}
');
	var status = Script.run(Script.haxeon(), ["run", source, "a", "b"], {env: env, log: log}),
		output = File.getContent(log);
	if (status != 0 || output != "hello a,b 2\nStatements.hx:9: traced\n")
		Script.fail('FAIL: top-level statements exited with $status; their output:\n$output');

	File.saveContent(source, "#!/usr/bin/env haxeon\nSys.println(1);\nfinal invalid:Int = \"text\";\n");
	checkScriptError([source], env, log, "Statements.hx:3:");
	File.saveContent(source, "function main() {}\nSys.println(1);\n");
	checkScriptError([source], env, log, "A script cannot declare main and also contain top-level statements");
	File.saveContent(source, "class Statements { static function main() {} }\nSys.println(1);\n");
	checkScriptError([source], env, log, "A script cannot declare main and also contain top-level statements");

	File.saveContent(source, "final value = 42;\nfunction main() Sys.println(value);\n");
	status = Script.run(Script.haxeon(), [source], {env: env, log: log});
	if (status != 0 || File.getContent(log) != "42\n")
		Script.fail('FAIL: an explicit main with module fields exited with $status; its output:\n${File.getContent(log)}');

	File.saveContent(source,
		"var count = 40;\nprivate final step = 2;\nfinal var add = () -> count += step;\n"
		+ "class Statements { static function main() Sys.println(add()); }\n");
	status = Script.run(Script.haxeon(), [source], {env: env, log: log});
	if (status != 0 || File.getContent(log) != "42\n")
		Script.fail('FAIL: a static main with module fields exited with $status; its output:\n${File.getContent(log)}');

	File.saveContent(source, "Sys.println(1);\n");
	var hxml = Path.join([work, "normal.hxml"]);
	File.saveContent(hxml, '-cp $work\n-main Statements\n--no-output\n');
	checkScriptError([hxml], env, log, "Expected Function, got Identifier");

	File.saveContent(Path.join([work, "Imported.hx"]), "class Imported {}\nSys.println(1);\n");
	File.saveContent(source, "import Imported;\nSys.println(1);\n");
	checkScriptError([source], env, log, "Expected Function, got Identifier");
}

function checkScriptError(arguments:Array<String>, env:Map<String, String>, log:String, expected:String):Void {
	var status = Script.run(Script.haxeon(), arguments, {env: env, log: log}),
		output = File.getContent(log);
	if (status == 0 || output.indexOf(expected) < 0)
		Script.fail('FAIL: expected "$expected", got status $status and output:\n$output');
}
