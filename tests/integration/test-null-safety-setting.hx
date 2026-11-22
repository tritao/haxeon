#!/usr/bin/env haxeon
/**
 * A project's `nullSafety` setting, end to end: `haxeon init` writes "strict"; a project that assigns null to a `String` fails to
 * build under "strict", builds with a warning under "warn", and builds clean when the setting is "off" or absent. A Haxe command
 * line's `--macro nullSafety(...)` checks as a project's setting does, and a command line without it is off.
 */
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;
import sys.io.File;

function main() {
	var root = Path.directory(Path.directory(Script.directory())),
		suiteOut = Sys.getEnv("HAXEON_SUITE_OUT"),
		work = Path.join([
			suiteOut == null || suiteOut == "" ? Path.join([root, "out"]) : suiteOut,
			"test-null-safety-setting"
		]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	FileSystem.createDirectory(Path.join([work, "fresh"]));

	var fresh = Path.join([work, "fresh"]), log = Path.join([work, "init.log"]);
	expectStatus(haxeon(["init"], fresh, log), 0, log, "init");
	expectText(Path.join([fresh, "haxeon.toml"]), 'nullSafety = "strict"', "the haxeon.toml init writes");

	var source = "function main():Int {\n\tvar s:String = null;\n\treturn 0;\n}\n";
	for (setting in ["strict", "warn", "off", null]) {
		var name = setting == null ? "absent" : setting, project = Path.join([work, name]);
		FileSystem.createDirectory(Path.join([project, "src"]));
		write(project, "haxeon.toml",
			'version = 1\nentry = "Main"\nsourceRoots = ["src"]\n'
			+ (setting == null ? "" : 'nullSafety = "$setting"\n')
			+ '\n[package]\nname = "$name"\n');
		write(project, "src/Main.hx", source);
		log = Path.join([work, name + ".log"]);
		var status = haxeon(["build"], project, log), reported = File.getContent(log).indexOf("Null safety") >= 0;
		switch setting {
			case "strict":
				expectFailure(status, log, "a strict build of a null String");
				expectText(log, "Null safety", "a strict build's error");
			case "warn":
				expectStatus(status, 0, log, "a warn build of a null String");
				expectText(log, "Null safety", "a warn build's warning");
			case _:
				expectStatus(status, 0, log, 'a build with the setting $name');
				if (reported)
					Script.fail('FAIL: a build with the setting $name reported null safety:\n${File.getContent(log)}');
		}
	}

	// A Haxe command line is off unless a --macro nullSafety(...) turns the checker on for a path.
	var command = Path.join([work, "command"]);
	FileSystem.createDirectory(Path.join([command, "src"]));
	write(command, "src/Main.hx", "class Main {\n\tstatic function main() {\n\tvar s:String = null;\n\t}\n}\n");
	log = Path.join([work, "command-off.log"]);
	expectStatus(haxeon(["-cp", "src", "-main", "Main"], command, log), 0, log, "a command line without the macro");
	log = Path.join([work, "command-strict.log"]);
	expectFailure(haxeon(["-cp", "src", "-main", "Main", "--macro", "nullSafety('Main', Strict)"], command, log), log,
		"a command line with --macro nullSafety('Main', Strict)");
	expectText(log, "Null safety", "the command line's error");
	Sys.println("PASS: nullSafety in haxeon.toml and --macro nullSafety(...) check, warn and stay off as set");
}

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {cwd: directory, log: log});

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${File.getContent(log)}');

function expectFailure(status:Int, log:String, what:String):Void
	if (status == 0)
		Script.fail('FAIL: $what succeeded; its log:\n${File.getContent(log)}');

function expectText(log:String, text:String, what:String):Void
	if (File.getContent(log).indexOf(text) < 0)
		Script.fail('FAIL: $what lacks "$text"; the log:\n${File.getContent(log)}');

function write(directory:String, path:String, content:String):Void
	File.saveContent(Path.join([directory, path]), content);
