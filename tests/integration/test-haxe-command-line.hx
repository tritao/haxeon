#!/usr/bin/env haxeon
/**
 * Haxe command lines (`haxeon build.hxml`, `haxeon -cp src -main Main --hl out.hl`; tools.HaxeArguments): an .hxml file read as Haxe
 * reads it (comments, a value with spaces, a nested .hxml relative to the working directory), `--each` and `--next`, `--debug`,
 * `--cmd`, the last class path winning and the working directory searched last, `--cwd` for the rest of the run, a check when no
 * target is given, the help when there is nothing to compile, Haxe's "Type not found", a failing compilation stopping the rest,
 * and one usage error (status 2) that lists every unsupported option. Each built program prints what the same command line built
 * by the pinned stock Haxe prints, and the builds keep their state in the CLI's cache, not in the working directory.
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
			"test-haxe-command-line"
		]);
	for (directory in [work, cache(work)])
		if (FileSystem.exists(directory))
			Script.check("cmake", ["-E", "rm", "-rf", directory]);
	for (directory in ["src", "other/src", "first", "second", "haxe"])
		FileSystem.createDirectory(Path.join([work, directory]));
	write(work, "src/Main.hx", "class Main {\n\tstatic function main() {\n"
		+ "\t\t#if (greeting == \"hello world\") Sys.println(\"greeting: hello world\"); #else Sys.println(\"no greeting\"); #end\n"
		+ "\t\t#if debug Sys.println(\"debug\"); #end\n"
		+ "\t\tSys.println(\"helper \" + Helper.twice(21));\n\t}\n}\n");
	write(work, "src/Helper.hx", "class Helper {\n\tpublic static function twice(n:Int):Int return n * 2;\n}\n");
	write(work, "other/src/Other.hx", "class Other {\n\tstatic function main() Sys.println(\"other\");\n}\n");
	write(work, "first/Pick.hx", "class Pick {\n\tstatic function main() Sys.println(\"first\");\n}\n");
	write(work, "second/Pick.hx", "class Pick {\n\tstatic function main() Sys.println(\"second\");\n}\n");
	write(work, "Root.hx", "class Root {\n\tstatic function main() Sys.println(\"root\");\n}\n");
	write(work, "Broken.hx", "class Broken {\n\tstatic function main() {\n\t\tvar x:Int = \"text\";\n\t}\n}\n");
	// A comment line, indentation, a value with a space, and a `#` that is part of a line, not a comment, as in Haxe.
	write(work, "classes.hxml", "# the class paths\n-cp src\n  -cp other/src  \n");
	write(work, "build.hxml", "other/../classes.hxml\n-D greeting=hello world\n--each\n\n-main Main\n--hl out/main.hl\n"
		+ "--cmd echo ran > out/cmd.txt\n--next\n-main Other\n--debug\n--hl out/other.hl\n");

	// Each output of build.hxml, run by the VM, prints what stock Haxe's build of the same file prints.
	var log = Path.join([work, "build.log"]);
	expectStatus(haxeon(["build.hxml"], work, log), 0, log, "build.hxml");
	if (StringTools.trim(File.getContent(Path.join([work, "out", "cmd.txt"]))) != "ran")
		Script.fail("FAIL: --cmd did not run after the first compilation");
	var stock = Path.join([root, ".tools", "haxe", "haxe" + (Sys.systemName() == "Windows" ? ".exe" : "")]);
	var stockBuild = File.getContent(Path.join([work, "build.hxml"])).split("out/").join("haxe/");
	write(work, "stock.hxml", stockBuild);
	Script.check(stock, ["stock.hxml"], {cwd: work});
	for (name in ["main", "other"]) {
		var ours = Script.output(Script.vm(), [Path.join([work, "out", name + ".hl"])]),
			theirs = Script.output(Script.vm(), [Path.join([work, "haxe", name + ".hl"])]);
		if (ours != theirs)
			Script.fail('FAIL: $name.hl printed ${haxe.Json.stringify(ours)}, stock Haxe\'s ${haxe.Json.stringify(theirs)}');
	}
	if (Script.output(Script.vm(), [Path.join([work, "out", "other.hl"])]) != "other")
		Script.fail("FAIL: the compilation after --next did not build Other");
	// Only the module is written beside the user's output; the build's state stays in the CLI's cache.
	if (FileSystem.exists(Path.join([work, "out", "main.hl.hli"]))
		|| FileSystem.exists(Path.join([work, ".haxeon-hxml"]))
		|| !FileSystem.exists(cache(work)) || FileSystem.readDirectory(cache(work)).length != 2)
		Script.fail("FAIL: the builds did not keep their state, one directory each, in the CLI's hxml cache");

	// The working directory is a class path, looked in last; --cwd moves it for the rest of the run, so every path of the
	// compilation, the class path given before it too, is relative to the new one.
	log = Path.join([work, "root.log"]);
	expectStatus(haxeon(["-cp", "src", "-main", "Root", "--hl", "out/root.hl"], work, log), 0, log,
		"an entry in the working directory");
	if (Script.output(Script.vm(), [Path.join([work, "out", "root.hl"])]) != "root")
		Script.fail("FAIL: the entry in the working directory did not build");
	log = Path.join([work, "cwd.log"]);
	expectStatus(haxeon(["-cp", "src", "--cwd", "other", "-main", "Other", "--hl", "../out/cwd.hl"], work, log), 0, log,
		"a compilation after --cwd");
	if (Script.output(Script.vm(), [Path.join([work, "out", "cwd.hl"])]) != "other")
		Script.fail("FAIL: --cwd did not make the class path given before it relative to the new directory");

	// Nothing to compile prints the help and succeeds, as Haxe does; a missing entry is Haxe's "Type not found", status 1.
	log = Path.join([work, "nothing.log"]);
	expectStatus(haxeon(["-cp", "src", "--hl", "out/nothing.hl"], work, log), 0, log,
		"a command line with nothing to compile");
	if (File.getContent(log).indexOf("Usage: haxeon") < 0)
		Script.fail('FAIL: nothing to compile did not print the help; it printed:\n${File.getContent(log)}');
	log = Path.join([work, "missing.log"]);
	expectStatus(haxeon(["-main", "Missing", "--hl", "out/missing.hl"], work, log), 1, log, "a missing entry");
	if (StringTools.trim(File.getContent(log)) != "Type not found : Missing")
		Script.fail('FAIL: a missing entry printed:\n${File.getContent(log)}');

	// Arguments on the command line, Haxe's way: the class path given last is looked in first.
	log = Path.join([work, "pick.log"]);
	expectStatus(haxeon(["-cp", "first", "-cp", "second", "-main", "Pick", "--hl", "out/pick.hl"], work, log), 0, log,
		"the Haxe arguments");
	if (Script.output(Script.vm(), [Path.join([work, "out", "pick.hl"])]) != "second")
		Script.fail("FAIL: the class path given last did not win, as it does in Haxe");

	// No target: the program is only type-checked, so a type error fails and nothing is written.
	log = Path.join([work, "check.log"]);
	expectStatus(haxeon(["-main", "Broken"], work, log), 1, log, "a check of a program with a type error");
	if (File.getContent(log).indexOf("Broken.hx:3:") < 0)
		Script.fail('FAIL: the check did not report the type error; its log:\n${File.getContent(log)}');

	// A compilation that fails stops the ones after it, as in Haxe.
	write(work, "stops.hxml", "-main Broken\n--hl out/broken.hl\n--next\n-cp src\n-main Main\n--hl out/after.hl\n");
	log = Path.join([work, "stops.log"]);
	expectStatus(haxeon(["stops.hxml"], work, log), 1, log, "stops.hxml");
	if (FileSystem.exists(Path.join([work, "out", "after.hl"])))
		Script.fail("FAIL: the compilation after a failed one was built");

	// What Haxeon does not build is one usage error listing each option, and nothing is built.
	log = Path.join([work, "unsupported.log"]);
	expectStatus(haxeon(["build.hxml", "--js", "out/main.js", "--macro", "include('pack')", "-lib", "heaps",
		"--interp"], work, log),
		2, log, "unsupported options");
	var message = File.getContent(log);
	for (expected in ["--js out/main.js", "--macro include('pack')", "-lib heaps", "--interp"])
		if (message.indexOf(expected) < 0)
			Script.fail('FAIL: the usage error does not name "$expected"; it says:\n$message');
	Sys.println("PASS: .hxml files and Haxe arguments build as stock Haxe builds them; unsupported options are one usage error");
}

/** The CLI's hxml cache for this test, so it never reuses or disturbs the user's. */
function cache(work:String):String
	return work + "-cache";

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {
		cwd: directory,
		env: ["HAXEON_HXML_CACHE" => cache(directory)],
		log: log
	});

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${File.getContent(log)}');

function write(directory:String, path:String, content:String):Void
	File.saveContent(Path.join([directory, path]), content);
