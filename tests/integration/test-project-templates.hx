#!/usr/bin/env haxeon
/**
 * `haxeon create` and its templates (templates/README.md): each template makes a project that builds and runs as created; the
 * app builds through its Linux runner (docs/design/PROJECT_BUILDS.md) into an executable that runs alone, also built by plain
 * cmake, and opens its window for a few frames and writes a capture (`--frames`, `--capture`, under xvfb-run when there is one);
 * `create .` restores a deleted file and keeps the others; an unknown template, platform or option is a usage error.
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
			"test-project-templates"
		]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	FileSystem.createDirectory(work);

	// program: a console program that prints and exits 0.
	var log = Path.join([work, "create-program.log"]);
	expectStatus(haxeon(["create", "tool", "--template", "program"], work, log), 0, log, "create a program");
	var tool = Path.join([work, "tool"]);
	log = Path.join([work, "run-program.log"]);
	expectStatus(haxeon(["run"], tool, log), 0, log, "running the program");
	expectText(log, "Hello from tool", "the program's output");

	// app: an [app] section for this machine's platform, and a window that runs for a few frames and is captured.
	log = Path.join([work, "create-app.log"]);
	expectStatus(haxeon(["create", "hello-app", "--org", "org.example"], work, log), 0, log, "create an app");
	var app = Path.join([work, "hello-app"]),
		manifest = File.getContent(Path.join([app, "haxeon.toml"]));
	for (text in ['name = "Hello App"', 'id = "org.example.hello_app"', "[app]"])
		if (manifest.indexOf(text) < 0)
			Script.fail('FAIL: the app manifest lacks $text:\n$manifest');
	var capture = Path.join([work, "capture"]);
	log = Path.join([work, "run-app.log"]);
	var command = ["run", "--", "--frames=10", '--capture=$capture'];
	var status = Script.run("sh", ["-c", "command -v xvfb-run"], {log: Path.join([work, "xvfb.log"])}) == 0
		? Script.run("xvfb-run", ["-a", Script.haxeon()].concat(command), {cwd: app, log: log})
		: haxeon(command, app, log);
	expectStatus(status, 0, log, "running the app for ten frames");
	if (!FileSystem.exists(Path.join([capture, "frame.png"])))
		Script.fail('FAIL: the app wrote no frame.png to $capture; its log:\n${File.getContent(log)}');

	// On Linux the app is its runner's executable, with its module and native libraries beside it, and plain cmake builds it.
	if (Sys.systemName() == "Linux") {
		var executable = Path.join([app, "build", "linux", "app", "hello-app"]);
		for (file in [executable, executable + ".hl", Path.join([app, "build", "linux", "app", "libnativekit_ui.so"])])
			if (!FileSystem.exists(file))
				Script.fail('FAIL: the runner did not make $file');
		var plain = Path.join([work, "plain-cmake"]);
		log = Path.join([work, "plain-cmake.log"]);
		expectStatus(Script.run("cmake", [
			"-S",
			Path.join([app, "linux"]),
			"-B",
			plain,
			"-G",
			"Ninja",
			'-DCMAKE_MAKE_PROGRAM=${Path.join([root, ".tools", "ninja", "ninja"])}'
		], {log: log}), 0, log, "configuring the runner with cmake alone");
		log = Path.join([work, "plain-cmake-build.log"]);
		expectStatus(Script.run("cmake", ["--build", plain], {log: log}), 0, log,
			"building the runner with cmake alone");
		if (!FileSystem.exists(Path.join([plain, "app", "hello-app"])))
			Script.fail("FAIL: cmake alone did not make the app's executable");
	}

	// create . puts back what is missing and leaves the rest.
	write(app, "haxeon.toml", manifest + "# edited\n");
	FileSystem.deleteFile(Path.join([app, "src", "Main.hx"]));
	log = Path.join([work, "restore.log"]);
	expectStatus(haxeon(["create", "."], app, log), 0, log, "create . in the app");
	expectText(log, "src/Main.hx", "the restored file");
	if (!FileSystem.exists(Path.join([app, "src", "Main.hx"])))
		Script.fail("FAIL: create . did not restore src/Main.hx");
	if (File.getContent(Path.join([app, "haxeon.toml"])).indexOf("# edited") < 0)
		Script.fail("FAIL: create . changed haxeon.toml");

	for (bad in [
		["create", "x", "--template", "web"],
		["create", "y", "--platforms", "tv"],
		["create", "z", "--template", "program", "--platforms", "linux"]
	]) {
		log = Path.join([work, "usage.log"]);
		expectStatus(haxeon(bad, work, log), 2, log, bad.join(" "));
	}
	Sys.println("PASS: create makes a program and an app that build (through its runner) and run, restores missing files, and rejects bad options");
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
