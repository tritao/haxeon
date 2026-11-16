#!/usr/bin/env haxeon
/**
 * `haxeon script.hx` (tools.ScriptRun): a script builds quietly and runs with its arguments, its exit status, a dashed file name, the caller's
 * working directory and the modules beside it; a sibling that does not compile is not built; a compile error goes to
 * standard error and fails the run; and, outside Windows, a `#!/usr/bin/env haxeon` script runs as a program.
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
