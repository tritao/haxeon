#!/usr/bin/env haxeon
/**
 * `haxeon create` and its templates (templates/README.md): each template makes a project that builds and runs as created; the
 * app builds through this machine's runner (linux/, macos/ or windows/; docs/design/PROJECT_BUILDS.md) into an executable that
 * runs alone, also built by plain cmake and ahead of time, and opens its window for a few frames and writes a capture
 * (`--frames`, `--capture`, under xvfb-run when there is one); an app for a platform without a runner cannot be made;
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

	// console: a console program that prints and exits 0.
	var log = Path.join([work, "create-console.log"]);
	expectStatus(haxeon(["create", "tool", "-t", "console"], work, log), 0, log, "create a console program");
	var tool = Path.join([work, "tool"]);
	log = Path.join([work, "run-console.log"]);
	expectStatus(haxeon(["run"], tool, log), 0, log, "running the console program");
	expectText(log, "Hello from tool", "the console program's output");

	for (bad in [
		["create", "x", "--template", "web"],
		["create", "y", "--platforms", "tv"],
		["create", "z", "--template", "console", "--platforms", "linux"]
	]) {
		log = Path.join([work, "usage.log"]);
		expectStatus(haxeon(bad, work, log), 2, log, bad.join(" "));
	}

	// An app for a platform whose runner the template does not have yet cannot be made.
	log = Path.join([work, "create-ios.log"]);
	expectStatus(haxeon(["create", "w", "--platforms", "ios"], work, log), 2, log,
		"create an app without a runner");
	expectText(log, "The app template has no ios runner", "create an app without a runner");

	// app: an [app] section for every platform with a runner, built through this machine's, and a window that runs for a few frames and
	// is captured.
	log = Path.join([work, "create-app.log"]);
	expectStatus(haxeon(["create", "hello-app", "--org", "org.example"], work, log), 0, log, "create an app");
	var app = Path.join([work, "hello-app"]),
		manifest = File.getContent(Path.join([app, "haxeon.toml"]));
	for (text in [
		'name = "Hello App"',
		'id = "org.example.hello_app"',
		"[app]",
		'platforms = ["android", "linux", "macos", "web", "windows"]'
	])
		if (manifest.indexOf(text) < 0)
			Script.fail('FAIL: the app manifest lacks $text:\n$manifest');
	// Both web targets use the same page and the SDK loader.
	var webSdk = Path.join([root, "out", "sdk", "platforms", "web", "ui"]);
	for (target in FileSystem.exists(webSdk) ? ["wasm32", "wasm-gc"] : []) {
		log = Path.join([work, target + ".log"]);
		expectStatus(haxeon(["build", "--target", target], app, log), 0, log, 'building the $target web bundle');
		var bundle = Path.join([app, "build", "web", target]);
		for (file in [
			"index.html",
			"haxeon-host.js",
			"haxeon-build.js",
			"main.wasm",
			"ui/nativekit_ui_haxeon.wasm",
			"ui/assets/IBMPlexSans-Regular.ttf"
		])
			if (!FileSystem.exists(Path.join([bundle, file])))
				Script.fail('FAIL: the web bundle lacks $file');
	}
	log = Path.join([work, "android-plan.log"]);
	expectStatus(haxeon(["build", "--target", "android", "--plan"], app, log), 0, log, "planning the Android app");
	expectText(log, "app.hl.hcs", "the Android build's live baseline");
	var capture = Path.join([work, "capture"]);
	log = Path.join([work, "run-app.log"]);
	expectStatus(headless(Script.haxeon(), ["run", "--", "--frames=10", '--capture=$capture'], app, log), 0, log,
		"running the app for ten frames");
	expectRendered(capture, log, "the app");

	// The app is its runner's executable, with its module and native libraries where it finds them, and plain cmake builds it.
	var platform = switch Sys.systemName() {
		case "Windows": "windows";
		case "Mac": "macos";
		case _: "linux";
	}, built = appFiles(Path.join([app, "build", platform, "app"]), platform);
	for (file in [built.executable, built.module, built.library])
		if (!FileSystem.exists(file))
			Script.fail('FAIL: the runner did not make $file');
	// Ninja from PATH where the bootstrap pins none (on Windows, Visual Studio's).
	var plain = Path.join([work, "plain-cmake"]),
		ninja = Path.join([root, ".tools", "ninja", "ninja"]);
	log = Path.join([work, "plain-cmake.log"]);
	expectStatus(Script.run("cmake", ["-S", Path.join([app, platform]), "-B", plain, "-G", "Ninja"]
		.concat(FileSystem.exists(ninja) ? ['-DCMAKE_MAKE_PROGRAM=$ninja'] : []), {log: log}), 0, log,
		"configuring the runner with cmake alone");
	log = Path.join([work, "plain-cmake-build.log"]);
	expectStatus(Script.run("cmake", ["--build", plain], {log: log}), 0, log, "building the runner with cmake alone");
	if (!FileSystem.exists(appFiles(Path.join([plain, "app"]), platform).executable))
		Script.fail("FAIL: cmake alone did not make the app's executable");

	// A release build compiles the program ahead of time into the runner's executable: no module beside it, and it runs.
	log = Path.join([work, "release.log"]);
	expectStatus(haxeon(["build", "--build-mode=release"], app, log), 0, log, "building the app in release mode");
	if (FileSystem.exists(built.module))
		Script.fail("FAIL: the release build left a module beside the app compiled ahead of time");
	var releaseCapture = Path.join([work, "capture-release"]);
	log = Path.join([work, "run-release.log"]);
	expectStatus(headless(built.executable, ["--frames=3", '--capture=$releaseCapture'], null, log), 0, log,
		"running the app compiled ahead of time");
	expectRendered(releaseCapture, log, "the app compiled ahead of time");
	log = Path.join([work, "release-watch.log"]);
	expectStatus(haxeon(["run", "--build-mode=release", "--watch"], app, log), 2, log, "watching a release build");
	expectText(log, "compiled ahead of time and cannot be watched", "watching a release build");

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

	Sys.println("PASS: create makes a console program and an app that build (through its runner, also ahead of time) and run, restores missing files, and rejects bad options");
}

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {cwd: directory, log: log});

/** Runs a program that opens a window: under xvfb-run on Linux when there is one, as it is elsewhere. */
function headless(program:String, arguments:Array<String>, directory:Null<String>, log:String):Int
	return Sys.systemName() == "Linux" && Script.run("sh", ["-c", "command -v xvfb-run"], {log: log}) == 0
		? Script.run("xvfb-run", ["-a", program].concat(arguments), {cwd: directory, log: log})
		: Script.run(program, arguments, {cwd: directory, log: log});

/**
 * Where a runner's build puts the executable, the module and the UI package's library, in its `directory` (app/): together on
 * Linux and Windows, in a bundle on macOS.
 */
function appFiles(directory:String, platform:String):{executable:String, module:String, library:String} {
	var name = "hello-app";
	return switch platform {
		case "windows": {
			executable: Path.join([directory, name + ".exe"]),
			module: Path.join([directory, name + ".hl"]),
			library: Path.join([directory, "nativekit_ui.dll"])
		};
		case "macos": {
			executable: Path.join([directory, name + ".app", "Contents", "MacOS", name]),
			module: Path.join([directory, name + ".app", "Contents", "Resources", name + ".hl"]),
			library: Path.join([directory, name + ".app", "Contents", "Frameworks", "libnativekit_ui.dylib"])
		};
		case _: {
			executable: Path.join([directory, name]),
			module: Path.join([directory, name + ".hl"]),
			library: Path.join([directory, "libnativekit_ui.so"])
		};
	};
}

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${File.getContent(log)}');

/**
 * The capture `--capture` wrote: the frames the app rendered, and on Linux the window's image, which ImageMagick's `import`
 * takes from the X server.
 */
function expectRendered(capture:String, log:String, what:String):Void {
	var metrics = Path.join([capture, "frame-metrics.json"]);
	if (!FileSystem.exists(metrics))
		Script.fail('FAIL: $what wrote no frame-metrics.json to $capture; its log:\n${File.getContent(log)}');
	var rendered:Null<Int> = haxe.Json.parse(File.getContent(metrics)).renderedFrames;
	if (rendered == null || rendered < 1)
		Script.fail('FAIL: $what rendered no frame ($metrics); its log:\n${File.getContent(log)}');
	if (Sys.systemName() == "Linux" && !FileSystem.exists(Path.join([capture, "frame.png"])))
		Script.fail('FAIL: $what wrote no frame.png to $capture; its log:\n${File.getContent(log)}');
}

function expectText(log:String, text:String, what:String):Void
	if (File.getContent(log).indexOf(text) < 0)
		Script.fail('FAIL: $what lacks "$text"; the log:\n${File.getContent(log)}');

function write(directory:String, path:String, content:String):Void
	File.saveContent(Path.join([directory, path]), content);
