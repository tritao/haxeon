#!/usr/bin/env haxeon
/**
 * Project manifests in TOML and JSON: `haxeon init` writes a haxeon.toml that builds and runs; `haxeon migrate --dry-run`
 * prints the TOML and changes nothing, `haxeon migrate` replaces haxeon.json with it (dependency, format and android sections
 * included) and the project still builds; a directory with both files is a usage error naming both; `haxeon add` keeps a
 * haxeon.toml's comments, and `haxeon add NAME` writes the latest release of the haxeon registry as `NAME = "^VERSION"`. Each command has its own help.
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
			"test-project-manifests"
		]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	for (directory in ["fresh", "app/src", "lib/src/greet"])
		FileSystem.createDirectory(Path.join([work, directory]));

	for (command in ["init", "migrate"]) {
		var help = Path.join([work, command + "-help.log"]);
		expectStatus(haxeon([command, "--help"], work, help), 0, help, 'haxeon $command --help');
		if (File.getContent(help).indexOf('Usage: haxeon $command') < 0)
			Script.fail('FAIL: haxeon $command --help printed:\n${File.getContent(help)}');
	}

	// init writes TOML, which builds and runs.
	var fresh = Path.join([work, "fresh"]), log = Path.join([work, "init.log"]);
	expectStatus(haxeon(["init"], fresh, log), 0, log, "init");
	if (!FileSystem.exists(Path.join([fresh, "haxeon.toml"])) || FileSystem.exists(Path.join([fresh, "haxeon.json"])))
		Script.fail('FAIL: init did not write haxeon.toml alone');
	write(fresh, "src/Main.hx", "function main():Int {\n\tSys.println(\"fresh ran\");\n\treturn 0;\n}\n");
	log = Path.join([work, "fresh-run.log"]);
	expectStatus(haxeon(["run"], fresh, log), 0, log, "running the fresh project");
	expectText(log, "fresh ran", "the fresh project's output");
	log = Path.join([work, "init-again.log"]);
	expectStatus(haxeon(["init"], fresh, log), 1, log, "init over a project");
	expectText(log, "haxeon.toml already exists", "init over a project");

	// A JSON project with a path dependency on a JSON package, migrated.
	var app = Path.join([work, "app"]), lib = Path.join([work, "lib"]);
	write(lib, "haxeon.json", '{"version": 1, "package": {"name": "greet"}, "sourceRoots": ["src"]}\n');
	write(lib, "src/greet/Greeting.hx", "package greet;\n\nfunction text():String\n\treturn \"migrated ran\";\n");
	var json = '{\n\t"version": 1,\n\t"package": {"name": "app"},\n\t"entry": "Main",\n\t"sourceRoots": ["src"],\n'
		+ '\t"defines": ["app_define"],\n\t"dependencies": {"greet": {"path": "../lib"}},\n'
		+ '\t"format": {"indent": "spaces", "indentWidth": 2},\n'
		+ '\t"android": {"applicationId": "org.example.app", "label": "App \\"quoted\\""}\n}\n';
	write(app, "haxeon.json", json);
	write(app, "src/Main.hx",
		"function main():Int {\n\t#if app_define\n\tSys.println(greet.Greeting.text());\n\t#end\n\treturn 0;\n}\n");
	log = Path.join([work, "migrate-dry.log"]);
	expectStatus(haxeon(["migrate", "--dry-run"], app, log), 0, log, "migrate --dry-run");
	for (line in [
		"version = 1",
		"entry = \"Main\"",
		"defines = [\"app_define\"]",
		"[package]\nname = \"app\"",
		"[dependencies]\ngreet = { path = \"../lib\" }",
		"[format]\nindent = \"spaces\"\nindentWidth = 2",
		"label = \"App \\\"quoted\\\"\""
	])
		expectText(log, line, "the migrated manifest");
	if (File.getContent(Path.join([app, "haxeon.json"])) != json || FileSystem.exists(Path.join([app, "haxeon.toml"])))
		Script.fail("FAIL: migrate --dry-run changed the project");

	log = Path.join([work, "migrate.log"]);
	expectStatus(haxeon(["migrate"], app, log), 0, log, "migrate");
	if (FileSystem.exists(Path.join([app, "haxeon.json"])) || !FileSystem.exists(Path.join([app, "haxeon.toml"])))
		Script.fail("FAIL: migrate did not replace haxeon.json with haxeon.toml");
	log = Path.join([work, "migrated-run.log"]);
	expectStatus(haxeon(["run"], app, log), 0, log, "running the migrated project");
	expectText(log, "migrated ran", "the migrated project's output");
	// The format section reaches the formatter.
	write(app, "src/Formatted.hx", "class Formatted {\nfunction f() {}\n}\n");
	log = Path.join([work, "fmt.log"]);
	expectStatus(haxeon(["fmt", "src/Formatted.hx"], app, log), 0, log, "fmt in the migrated project");
	if (File.getContent(Path.join([app, "src/Formatted.hx"])) != "class Formatted {\n  function f() {}\n}\n")
		Script.fail('FAIL: fmt did not indent with two spaces:\n${File.getContent(Path.join([app, "src/Formatted.hx"]))}');
	log = Path.join([work, "migrate-toml.log"]);
	expectStatus(haxeon(["migrate"], app, log), 2, log, "migrate of a TOML project");

	// Both files: a usage error that names both, for a build and for a dependency's directory.
	write(app, "haxeon.json", json);
	log = Path.join([work, "both.log"]);
	expectStatus(haxeon(["build"], app, log), 2, log, "a build beside both manifests");
	expectText(log, "has both haxeon.toml and haxeon.json", "the error for both manifests");
	FileSystem.deleteFile(Path.join([app, "haxeon.json"]));
	write(lib, "haxeon.toml", "version = 1\n[package]\nname = \"greet\"\n");
	log = Path.join([work, "both-dependency.log"]);
	expectStatus(haxeon(["build"], app, log), 2, log, "a dependency with both manifests");
	expectText(log, Path.join(["lib"]) + " has both haxeon.toml and haxeon.json",
		"the dependency's error for both manifests");
	FileSystem.deleteFile(Path.join([lib, "haxeon.json"]));

	// add keeps the file as it was around the new entry.
	write(app, "haxeon.toml", "# The app.\n" + File.getContent(Path.join([app, "haxeon.toml"])));
	log = Path.join([work, "add.log"]);
	expectStatus(haxeon(["add", "--git", "https://example.org/extra.git", "--rev", "v1", "extra"], app, log), 0, log,
		"add");
	var manifest = File.getContent(Path.join([app, "haxeon.toml"]));
	if (!StringTools.startsWith(manifest, "# The app.\n")
		|| manifest.indexOf("greet = { path = \"../lib\" }\nextra = { git = \"https://example.org/extra.git\", rev = \"v1\" }\n")
		< 0)
		Script.fail('FAIL: add did not insert the dependency into [dependencies]:\n$manifest');

	// add NAME takes the latest release that is not yanked from the haxeon registry, written as its version range alone: the SDK's
	// registry for the packages it has (a checkout's lists packages/ at Haxeon's version), the source cache's for the others.
	var cache = Path.join([work, "source-cache"]),
		registry = Path.join([cache, "registry", haxe.crypto.Sha256.encode("haxeon")]);
	FileSystem.createDirectory(registry);
	write(registry, "index.json",
		'{"version":1,"packages":{"widgets":{"versions":[{"version":"1.3.1","checksum":"a"},{"version":"1.4.0","checksum":"b","yanked":true}]}}}\n');
	Sys.putEnv("HAXEON_SOURCE_CACHE", cache);
	for (added in [{key: "ui", value: "^"}, {key: "widgets", value: "^1.3.1\""}]) {
		log = Path.join([work, 'add-${added.key}.log']);
		expectStatus(haxeon(["add", added.key], app, log), 0, log, 'add ${added.key}');
		if (File.getContent(Path.join([app, "haxeon.toml"])).indexOf('\n${added.key} = "${added.value}') < 0)
			Script.fail('FAIL: add ${added.key} did not write ${added.key} = "${added.value}...:\n${File.getContent(Path.join([app, "haxeon.toml"]))}');
	}
	log = Path.join([work, "add-missing.log"]);
	expectStatus(haxeon(["add", "missing"], app, log), 2, log, "add of a package the registry lacks");
	expectText(log, 'The registry has no package "missing"', "the error for a package the registry lacks");
	Sys.println("PASS: init writes TOML, migrate converts JSON, both manifests are refused, add keeps comments and adds registry packages");
}

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {cwd: directory, log: log});

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${File.getContent(log)}');

function expectText(log:String, text:String, what:String):Void
	if (File.getContent(log).indexOf(text) < 0)
		Script.fail('FAIL: $what lacks "$text"; the log:\n${File.getContent(log)}');

function write(directory:String, path:String, content:String):Void
	File.saveContent(Path.join([directory, path]), content);
