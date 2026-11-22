#!/usr/bin/env haxeon
/**
 * `haxeon check`, `haxeon test` and `haxeon clean` on a project: a check reports a type error and a missing entry point
 * (status 1) and writes no module, then passes once they are fixed; `test` builds and runs the project in tests (a haxeon.toml
 * beside the root's haxeon.json), 0 when it passes and 1 when it fails, and names the file it looked for when there is none; `clean` removes the project's and its tests'
 * build directories and nothing else. Each command has its own help.
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
			"test-project-verbs"
		]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	for (directory in ["src", "tests/src"])
		FileSystem.createDirectory(Path.join([work, directory]));
	write(work, "haxeon.json",
		'{"version": 1, "package": {"name": "verbs"}, "entry": "Main", "sourceRoots": ["src"], "target": "host"}\n');
	write(work, "src/Main.hx", "function main():Int {\n\tvar x:Int = \"text\";\n\treturn 0;\n}\n");
	write(work, "notes.txt", "kept\n");

	for (command in ["check", "test", "clean"]) {
		var help = Path.join([work, command + "-help.log"]);
		expectStatus(haxeon([command, "--help"], work, help), 0, help, 'haxeon $command --help');
		if (File.getContent(help).indexOf('Usage: haxeon $command') < 0)
			Script.fail('FAIL: haxeon $command --help printed:\n${File.getContent(help)}');
	}

	var log = Path.join([work, "check-error.log"]);
	expectStatus(haxeon(["check"], work, log), 1, log, "a check of a type error");
	if (File.getContent(log).indexOf("src/Main.hx:2:") < 0)
		Script.fail('FAIL: the check did not report the type error; its log:\n${File.getContent(log)}');
	if (FileSystem.exists(Path.join([work, "build", "host", "main.hl"])))
		Script.fail("FAIL: a check wrote a module");
	// A check requires the entry point, as a build does.
	write(work, "src/Main.hx", "function notMain():Int return 0;\n");
	log = Path.join([work, "check-entry.log"]);
	expectStatus(haxeon(["check"], work, log), 1, log, "a check of a program without main");
	if (File.getContent(log).indexOf("entry point") < 0)
		Script.fail('FAIL: the check did not report the missing entry point; its log:\n${File.getContent(log)}');
	write(work, "src/Main.hx", "function main():Int return 0;\n");
	log = Path.join([work, "check.log"]);
	expectStatus(haxeon(["check"], work, log), 0, log, "a check of a correct program");
	log = Path.join([work, "check-options.log"]);
	expectStatus(haxeon(["check", "--watch"], work, log), 2, log, "a check with a build-only option");

	log = Path.join([work, "no-tests.log"]);
	expectStatus(haxeon(["test"], work, log), 1, log, "test without a tests project");
	if (File.getContent(log).indexOf(Path.join(["tests", "haxeon.toml"])) < 0)
		Script.fail('FAIL: test without tests did not name tests/haxeon.toml; its log:\n${File.getContent(log)}');
	write(work, "tests/haxeon.toml",
		'version = 1\nentry = "TestMain"\nsourceRoots = ["src"]\ntarget = "host"\n\n[package]\nname = "verbs-tests"\n');
	// The tests fail when given arguments, so one project shows both outcomes.
	write(work, "tests/src/TestMain.hx",
		"function main():Int {\n\tSys.println(\"ran \" + Sys.args().length);\n\treturn Sys.args().length == 0 ? 0 : 3;\n}\n");
	log = Path.join([work, "test-pass.log"]);
	expectStatus(haxeon(["test"], work, log), 0, log, "passing tests");
	if (File.getContent(log).indexOf("ran 0") < 0)
		Script.fail('FAIL: the tests did not run; the log:\n${File.getContent(log)}');
	log = Path.join([work, "test-fail.log"]);
	expectStatus(haxeon(["test", "--", "fail"], work, log), 1, log, "failing tests");

	expectStatus(haxeon(["build"], work, Path.join([work, "build.log"])), 0, Path.join([work, "build.log"]),
		"the build");
	log = Path.join([work, "clean.log"]);
	expectStatus(haxeon(["clean"], work, log), 0, log, "clean");
	for (removed in ["build", "tests/build"])
		if (FileSystem.exists(Path.join([work, removed])))
			Script.fail('FAIL: clean left $removed');
	for (kept in ["haxeon.json", "src/Main.hx", "notes.txt", "tests/haxeon.toml"])
		if (!FileSystem.exists(Path.join([work, kept])))
			Script.fail('FAIL: clean removed $kept');
	Sys.println("PASS: check, test and clean work on a project");
}

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {cwd: directory, log: log});

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${File.getContent(log)}');

function write(directory:String, path:String, content:String):Void
	File.saveContent(Path.join([directory, path]), content);
