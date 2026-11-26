#!/usr/bin/env haxeon
/**
 * Smoke test of a release archive (`haxeon dev package`, docs/DEVELOPMENT.md, Releases), as a user meets it: unpacked into a
 * directory of its own outside any checkout, with a home directory of its own so every cache starts cold, and nothing but the
 * archive's bin/haxeon. It runs --version, doctor, create (console) + build + run + check of a new project and a script,
 * checks that the compiles ran the compiler the archive is meant to run, and runs a program under `run --watch`, edits it and
 * sees the running program patched. Where the app template has a runner for this platform it then creates the app, which
 * takes its UI package from the release's haxeon registry, builds it through its runner in development and release mode (a C
 * toolchain, and on Linux GTK's development files, are needed) and runs each for a few frames, under xvfb-run when there is
 * one, patches the app running under `run --watch` (not on Windows), then builds and runs a program that uses the nativekit
 * package from the same registry and one that uses filesystem, a NativeKit module's package built on the same NativeKit.
 * Nothing may be written into the release's directory:
 *
 *   scripts/haxeon scripts/smoke-test-release.hx ARCHIVE --aot      the CLI and compiler built ahead of time (bin/haxeon-aot)
 *   scripts/haxeon scripts/smoke-test-release.hx ARCHIVE --no-aot   the compiler's bytecode on the VM (bin/haxeon-compiler.hl)
 *
 * With --aot it then times the same cold build on the VM (the archive without bin/haxeon-aot), which also checks the
 * bytecode a release falls back to. The release workflow runs it on each platform's archive, with the checkout's haxeon: the
 * release under test is only ever the program being tested, so a broken one still gets a report.
 */
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Output;
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;
import sys.io.ChildProcess;
import sys.io.File;

/** The platform as the app template names its runners (`AppRunner.hostPlatform`). */
final PLATFORM = switch Sys.systemName() {
	case "Windows": "windows";
	case "Mac": "macos";
	case _: "linux";
};

final WINDOWS = PLATFORM == "windows";
final SUFFIX = WINDOWS ? ".exe" : "";

/** The longest any one command may run, in seconds: a cold app build takes a few minutes, a hung one forever. */
final COMMAND_LIMIT = 900;

/** This run's scratch directory, removed at the end and on a failure. */
var work = "";

function main() {
	var arguments = Sys.args();
	if (arguments.length != 2 || (arguments[1] != "--aot" && arguments[1] != "--no-aot"))
		Script.fail("usage: haxeon scripts/smoke-test-release.hx ARCHIVE --aot|--no-aot", 2);
	var archive = FileSystem.fullPath(arguments[0]), expectAot = arguments[1] == "--aot";
	work = scratchDirectory();

	var root = unpack(archive, Path.join([work, "unpacked"])), haxeon = Path.join([root, "bin", "haxeon" + SUFFIX]);
	isolate(Path.join([work, "home"]));

	Sys.println("== haxeon --version");
	var version = stdout("haxeon --version", haxeon, ["--version"], work);
	Sys.println(version);
	var commit = ~/^commit = "(.*)"/m;
	if (!commit.match(File.getContent(Path.join([root, "haxeon-sdk.toml"])))
		|| version.indexOf('compiler ${StringTools.trim(commit.matched(1))}') < 0)
		fail("--version does not name the release's commit");

	Sys.println("== haxeon doctor");
	var doctor = execute(haxeon, ["doctor"], work);
	Sys.println(doctor.out);
	if (doctor.status != 0)
		fail("haxeon doctor");
	if (expectAot) {
		if (!~/^ok: CLI and compiler built ahead of time/m.match(doctor.out))
			fail("doctor does not report the AOT compiler current");
	} else {
		if (!~/^not built: CLI and compiler built ahead of time/m.match(doctor.out))
			fail("doctor does not report the AOT compiler not built");
		if (!~/^ok: compiler bytecode/m.match(doctor.out))
			fail("doctor does not report the compiler bytecode");
	}

	Sys.println("== haxeon create (console), build, run, check");
	var projects = Path.join([work, "projects"]), console = Path.join([projects, "hello"]);
	var aotSeconds = projectRound(root, console);
	checkCompiler(root, expectAot);

	Sys.println("== console release executable");
	must("console release build", haxeon, ["build", "--build-mode", "release"], console);
	var output = stdout("console release executable", Path.join([console, "build", PLATFORM, "bin", "hello" + SUFFIX]),
		[], console);
	if (output != "release smoke: 1,4,9")
		fail('console release executable printed: $output');

	Sys.println("== haxeon script.hx");
	File.saveContent(Path.join([projects, "hello-script.hx"]),
		'function main() {\n\tSys.println("script ok " + Sys.args().join(" "));\n}\n');
	output = stdout("script run", haxeon, ["hello-script.hx", "a", "b"], projects);
	if (output != "script ok a b")
		fail('the script printed: $output');

	// The tools that carry the compiler, which a release runs as roles of its compiler's program.
	Sys.println("== haxeon lint (a typed rule), haxeon ffi audit, and haxeon dev's refusal");
	must("haxeon lint --only unbound-local", haxeon, ["lint", "--only", "unbound-local", "src/Main.hx"], console);
	if (onPath("clang")) {
		var header = Path.join([projects, "point.h"]);
		File.saveContent(header, "typedef struct point { int x; int y; } point;\nint point_sum(const point *p);\n");
		var audit = execute(haxeon, [
			"ffi", "audit", "--target=x86_64-linux-gnu", "--target=arm64-apple-darwin", "--profile=portable-abi64",
			header
		], projects);
		if (audit.status != 0 || !StringTools.startsWith(audit.out, "PASS:"))
			fail('haxeon ffi audit printed: ${audit.out}${audit.err}');
	}
	var refusal = execute(haxeon, ["dev", "tool-build-mode"], projects);
	if (refusal.status == 0)
		fail('haxeon dev ran in a release: ${refusal.out}');
	if ((refusal.out + refusal.err).indexOf("is a release") < 0)
		fail('haxeon dev\'s refusal does not say why: ${refusal.out}${refusal.err}');

	// The live host the release ships, the compile server's patches, and the edit seen in the running program.
	Sys.println("== haxeon run --watch: an edit patches the running program");
	var live = Path.join([projects, "live"]), liveLog = Path.join([work, "live.log"]);
	FileSystem.createDirectory(live);
	must("haxeon create of the live program", haxeon, ["create", ".", "--template", "console"], live);
	writeLiveSource("one", live);
	var watch = new Watch(haxeon, ["run", "--watch"], live, liveLog);
	watch.waitFor(liveLog, ~/^live value one/m, 300);
	writeLiveSource("two", live);
	watch.waitFor(liveLog, ~/^live value two/m, 120);
	if (content(Path.join([live, "build", "host", "main.hl.watch-events.jsonl"])).indexOf('"kind":"patch-applied"') < 0)
		watch.fail("the edit reached the program, but not as a patch");
	File.saveContent(Path.join([live, "stop"]), "");
	var status = watch.waitExit(120);
	if (status != 0)
		watch.fail('haxeon run --watch exited with status $status');

	// `haxeon create` makes an app only for a platform the template has a runner for.
	if (FileSystem.isDirectory(Path.join([root, "templates", "app", PLATFORM])))
		appRound(root, haxeon, projects);

	var manifest = FileSystem.stat(Path.join([root, "haxeon-sdk.toml"])).mtime.getTime(), written = [];
	walk(root,
		(file) -> if (written.length < 3 && FileSystem.stat(file).mtime.getTime() > manifest) written.push(file));
	if (written.length > 0)
		fail('the release wrote into its own directory: ${written.join(", ")}');

	if (expectAot) {
		Sys.println("== the same cold build on the VM (without bin/haxeon-aot)");
		var jitRoot = unpack(archive, Path.join([work, "jit"]));
		FileSystem.deleteFile(Path.join([jitRoot, "bin", "haxeon-aot" + SUFFIX]));
		isolate(Path.join([work, "jit-home"]));
		var vmSeconds = projectRound(jitRoot, Path.join([work, "jit-projects", "hello"]));
		checkCompiler(jitRoot, false);
		Sys.println('Cold build of a new project: ${seconds(aotSeconds)} s with the compiler built ahead of time, ${seconds(vmSeconds)} s on the VM');
	} else
		Sys.println('Cold build of a new project: ${seconds(aotSeconds)} s on the VM');
	cleanup();
	Sys.println('release smoke test passed: ${Path.withoutDirectory(archive)}');
}

/**
 * The app template from the release's templates, its UI package from the release's haxeon registry, built through its
 * runner against the release's SDK with this machine's C toolchain and run for a few frames; then programs with a native
 * package and a NativeKit module's package from the same registry.
 */
function appRound(root:String, haxeon:String, projects:String):Void {
	var headless = onPath("xvfb-run") ? ["xvfb-run", "-a"] : [];
	Sys.println("== haxeon create (app), build, run, and the same in release mode");
	var app = Path.join([projects, "hello-app"]);
	must("haxeon create", haxeon, ["create", "hello-app"], projects);
	if (!~/^ui = \{ registry = "haxeon", version = "\^/m.match(File.getContent(Path.join([app, "haxeon.toml"]))))
		fail("the app's manifest does not use the UI package from the haxeon registry");
	for (target in ["wasm32", "wasm-gc"]) {
		must('web bundle for $target', haxeon, ["build", "--target", target], app);
		if (!Script.sameContent(Path.join([app, "build", "web", target, "haxeon-host.js"]),
			Path.join([root, "platforms", "web", "haxeon-host.js"])))
			fail("staged web loader");
	}
	if (FileSystem.exists(Path.join([root, "platforms", "android", "haxeon-host.aar"]))) {
		var inputs = "build/generated/android/inputs.properties";
		must("Android asset preparation", haxeon, ["build", "--target", "android", "--gradle-inputs", inputs], app);
		if (!~/^host=.*haxeon-host\.aar$/m.match(File.getContent(Path.join([app, inputs]))))
			fail("Android runner did not find the release host");
	}

	must("haxeon build of the app", haxeon, ["build"], app);
	var capture = Path.join([work, "capture"]);
	mustRun("haxeon run of the app", headless.concat([haxeon, "run", "--", "--frames=3", '--capture=$capture']), app);
	if (!captured(capture))
		fail("the app captured no rendered frame");
	must("haxeon install of the app", haxeon, ["install"], app);
	if (content(Path.join([app, "haxeon.lock"])).indexOf('"checksum"') < 0)
		fail("the release wrote no checksums into the app's haxeon.lock");
	must("haxeon build --build-mode=release of the app", haxeon, ["build", "--build-mode=release"], app);
	var appDirectory = Path.join([app, "build", PLATFORM, "app"]);
	if (FileSystem.exists(Path.join([appDirectory, "hello-app.hl"])))
		fail("the release build left a module beside the app");
	// Where the runner puts the executable in its directory is the platform's (a bundle on macOS).
	var executable:Null<String> = null;
	walk(appDirectory,
		(file) -> if (executable == null && Path.withoutDirectory(file) == "hello-app" + SUFFIX) executable = file);
	if (executable == null)
		fail('the release build made no hello-app$SUFFIX under $appDirectory');
	var releaseCapture = Path.join([work, "capture-release"]);
	mustRun("the app compiled ahead of time", headless.concat([executable, "--frames=3", '--capture=$releaseCapture']),
		app);
	if (!captured(releaseCapture))
		fail("the app compiled ahead of time captured no rendered frame");

	// The live host in the app's runner. The app runs until its window closes, so the test stops it once a patch applied. An
	// edit made before the watch took its first snapshot goes unseen, and one the host sees before it loaded the first module
	// is no patch but the module it loads, so it edits until one applies.
	if (!WINDOWS) {
		Sys.println("== haxeon run --watch of the app: an edit patches the running app");
		var log = Path.join([work, "live-app.log"]),
			command = headless.concat([haxeon, "run", "--watch"]),
			watch = new Watch(command[0], command.slice(1), app, log),
			events = Path.join([app, "build", "host", "main.hl.watch-events.jsonl"]),
			source = Path.join([app, "src", "Main.hx"]),
			patched = () -> content(events).indexOf('"kind":"patch-applied"') >= 0;
		watch.waitFor(events, null, 300);
		for (edit in 1...7) {
			File.saveContent(source,
				~/(You|Edit[0-9]+) clicked/g.replace(File.getContent(source), 'Edit$edit clicked'));
			if (watch.waitUntil(patched, 40))
				break;
		}
		if (!patched())
			watch.fail("no edit patched the running app");
		watch.stop();
	}

	// A program, not an app, with a native package from the release's registry: its CMake build runs in the shared native
	// cache, which for a release is in the user's cache, with the SDK's CMake scripts and the Ninja on PATH.
	Sys.println("== a program with a native package (nativekit) from the release's registry");
	var native = consoleProject(haxeon, Path.join([projects, "native-program"]), "nativekit",
		'function main():Int {\n\tSys.println("native program ok");\n\treturn 0;\n}\n');
	must("haxeon build of a program with a native package", haxeon, ["build"], native);
	// The native package's up-to-date check (CMake and Ninja) prints even under --quiet; the program's line is the last.
	var output = stdout("haxeon run of a program with a native package", haxeon, ["run", "--quiet"], native);
	if (lastLines(output, 1) != "native program ok")
		fail('the program with a native package printed: $output');
	var nativeCache = Path.join([Sys.getEnv("HOME"), ".haxeon", "cache", "native"]);
	if (!FileSystem.isDirectory(nativeCache))
		fail("the native package was not built in the user's cache");

	// A NativeKit module's package (filesystem), whose CMake project builds the module on the nativekit package's build
	// that the program above left in the cache.
	Sys.println("== a program with a NativeKit module's package (filesystem) from the release's registry");
	// The module confines a root with the kernel's root-relative resolution, and reports Unsupported where the kernel has
	// none (macOS before it): that is its answer there, not a failure of the package.
	var module = consoleProject(haxeon, Path.join([projects, "module-program"]), "filesystem",
		'function main():Int {\n\tvar root:haxeon.filesystem.FileSystemRoot;\n'
		+ '\ttry root = new haxeon.filesystem.FileSystemRoot(Sys.getCwd()) catch (error:haxeon.platform.NativeKitError) {\n'
		+ '\t\tif (error.result != nativekit.ffi.NativeKitTypes.Result.ErrorUnsupported) throw error;\n'
		+ '\t\tSys.println("module program ok unsupported");\n\t\treturn 0;\n\t}\n'
		+ '\tSys.println("module program ok " + (root.stat("").get_kind() == nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntryKind.Directory));\n'
		+ '\troot.close();\n\treturn 0;\n}\n');
	must("haxeon build of a program with a NativeKit module's package", haxeon, ["build"], module);
	output = stdout("haxeon run of a program with a NativeKit module's package", haxeon, ["run", "--quiet"], module);
	final moduleResult = lastLines(output, 1);
	if (moduleResult != "module program ok true"
		&& !(PLATFORM == "macos" && moduleResult == "module program ok unsupported"))
		fail('the program with filesystem printed: $output');
	var trees = 0;
	for (entry in FileSystem.readDirectory(nativeCache)) {
		var directory = Path.join([nativeCache, entry]);
		if (!FileSystem.isDirectory(directory))
			continue;
		if (StringTools.startsWith(entry, "nativekit-"))
			trees++;
		for (child in FileSystem.readDirectory(directory))
			if (StringTools.startsWith(child, "nativekit-") && FileSystem.isDirectory(Path.join([directory, child])))
				trees++;
	}
	if (trees != 1)
		fail('NativeKit was built in $trees trees of the native cache, not one');
}

/** Creates a console project in `directory`, adds `dependency` and writes its Main.hx. */
function consoleProject(haxeon:String, directory:String, dependency:String, main:String):String {
	FileSystem.createDirectory(directory);
	must("haxeon create", haxeon, ["create", ".", "--template", "console"], directory);
	must('haxeon add $dependency', haxeon, ["add", dependency], directory);
	File.saveContent(Path.join([directory, "src", "Main.hx"]), main);
	return directory;
}

/** Builds, runs and checks a new project in `project` with the release at `root`; returns the cold build's time. */
function projectRound(root:String, project:String):Float {
	var haxeon = Path.join([root, "bin", "haxeon" + SUFFIX]);
	FileSystem.createDirectory(project);
	must("haxeon create", haxeon, ["create", ".", "--template", "console"], project);
	File.saveContent(Path.join([project, "src", "Main.hx"]),
		'function main():Int {\n\tSys.println("release smoke: " + [for (i in 1...4) i * i].join(","));\n\treturn 0;\n}\n');
	var started = Sys.time();
	must("haxeon build", haxeon, ["build"], project);
	var buildTime = Sys.time() - started;
	var output = stdout("haxeon run", haxeon, ["run", "--quiet"], project);
	if (output != "release smoke: 1,4,9")
		fail('haxeon run printed: $output');
	must("haxeon check", haxeon, ["check"], project);
	return buildTime;
}

/**
 * Whether this run's compiles went through the expected compiler: nothing was built from sources into the session
 * directory (a release has no Haxe to build with), and on Linux and macOS the resident worker is that compiler.
 */
function checkCompiler(root:String, aot:Bool):Void {
	var built:Null<String> = null;
	walk(Sys.getEnv("HOME"),
		(file) -> if (built == null && Path.extension(file) == "hl" && file.indexOf("compiler") >= 0) built = file);
	if (built != null)
		fail('the compiler was built from sources: $built');
	if (!WINDOWS) {
		var worker = aot ? '$root/bin/haxeon-aot serve' : '$root/bin/hl $root/bin/haxeon-compiler.hl serve';
		if (execute("pgrep", ["-f", worker], work).status != 0) {
			var running = [
				for (line in execute("ps", ["-ax", "-o", "command="], work).out.split("\n"))
					if (line.indexOf("haxeon") >= 0 || line.indexOf(" serve") >= 0) line
			];
			// What the release's client left in its session directory: none means it never started a server.
			var sessions = Path.join([Sys.getEnv("XDG_CACHE_HOME"), "haxeon", "compiler"]), left = [];
			if (FileSystem.exists(sessions))
				for (name in FileSystem.readDirectory(sessions)) {
					left.push(name);
					if (Path.extension(name) == "log")
						left.push(lastLines(content(Path.join([sessions, name])), 20));
				}
			fail('no compile server of the expected compiler (AOT: $aot) is running: expected "$worker", running:\n'
				+ running.join("\n") + '\nsession directory $sessions:\n'
				+ (left.length == 0 ? "(none)" : left.join("\n")));
		}
	}
}

/**
 * A program `run --watch` patches, as its entry class declares what the live host calls: start, tick and close, and the
 * state methods a reload calls. Each tick prints `value`; the program ends when its directory holds a file `stop`.
 */
function writeLiveSource(value:String, project:String):Void
	File.saveContent(Path.join([project, "src", "Main.hx"]), [
		'class Main {',
		'	static function value():String return "$value";',
		'	public static function start(arguments:String):Void {}',
		'	public static function tick():Int {',
		'		Sys.println("live value " + value());',
		'		Sys.sleep(0.1);',
		'		return sys.FileSystem.exists("stop") ? 0 : 1;',
		'	}',
		'	public static function close():Int return 0;',
		'	public static function saveState():String return "";',
		'	public static function restoreState(state:String):Void {}',
		'	static function main():Void {}',
		'}',
		''
	].join("\n"));

/** What --capture wrote: the frames the app rendered, and on Linux the window's image, which ImageMagick's import takes. */
function captured(directory:String):Bool
	return ~/"renderedFrames": *[1-9]/.match(content(Path.join([directory, "frame-metrics.json"])))
		&& (PLATFORM != "linux" || FileSystem.exists(Path.join([directory, "frame.png"])));

/**
 * Unpacks the archive into `directory` and returns the release root, the archive's one top directory, with symbolic links
 * resolved as the launcher resolves its own path (macOS's temporary directory is one). CMake unpacks both kinds of archive.
 */
function unpack(archive:String, directory:String):String {
	FileSystem.createDirectory(directory);
	if (!StringTools.endsWith(archive, ".tar.gz") && !StringTools.endsWith(archive, ".zip"))
		fail('unknown archive type: $archive');
	must("unpacking the archive", "cmake", ["-E", "tar", "xf", archive], directory);
	var entries = FileSystem.readDirectory(directory);
	if (entries.length != 1 || !FileSystem.exists(Path.join([directory, entries[0], "haxeon-sdk.toml"])))
		fail("the archive does not hold one release directory");
	var root = FileSystem.fullPath(Path.join([directory, entries[0]]));
	if (~/^source/m.match(File.getContent(Path.join([root, "haxeon-sdk.toml"]))))
		fail("the release's manifest names a checkout");
	return root;
}

/** A user's environment: no checkout's variables, and a home of its own so caches and compiler sessions start empty. */
function isolate(home:String):Void {
	for (name in [
		"HAXEON_SDK", "HAXEON_COMPILER_SOURCE", "HAXEON_COMPILER_SESSION_DIR", "HAXEON_ARTIFACT_CACHE",
		"HAXEON_SCRIPT_CACHE",
		"HAXEON_NATIVE_READY", "HAXEON_COMPILER_SERVER", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"
	])
		Sys.putEnv(name, null);
	var local = Path.join([home, "AppData", "Local"]);
	for (name => value in [
		"HOME" => home,
		"USERPROFILE" => home,
		"LOCALAPPDATA" => local,
		"XDG_CACHE_HOME" => Path.join([home, ".cache"])
	])
		Sys.putEnv(name, value);
	FileSystem.createDirectory(local);
}

/** A program started in the background whose output goes to a log, as a shell's `command > log 2>&1 &` does. */
class Watch {
	final process:ChildProcess;
	final output:Output;
	final log:String;
	final buffer = Bytes.alloc(65536);

	public function new(command:String, arguments:Array<String>, cwd:String, log:String) {
		this.log = log;
		output = File.write(log, true);
		// Its own process group, so stopping it ends the CLI, the app it launched and any xvfb-run alike.
		process = ChildProcess.spawn(command, arguments, cwd);
	}

	/** Copies what the program printed so far into its log. */
	function drain():Void {
		var count = process.readStdout(buffer, 0, buffer.length);
		while (count > 0) {
			output.writeBytes(buffer, 0, count);
			count = process.readStdout(buffer, 0, buffer.length);
		}
		count = process.readStderr(buffer, 0, buffer.length);
		while (count > 0) {
			output.writeBytes(buffer, 0, count);
			count = process.readStderr(buffer, 0, buffer.length);
		}
		output.flush();
	}

	/** Waits up to `seconds` for `file` to exist and, unless `pattern` is null, to match it; fails if the program exits. */
	public function waitFor(file:String, pattern:Null<EReg>, seconds:Float):Void
		if (!waitUntil(() -> FileSystem.exists(file) && (pattern == null || pattern.match(content(file))), seconds))
			fail('$file did not match ${pattern == null ? "anything" : "the expected line"} in $seconds s');

	/** Waits up to `seconds` for `done`; false when the time runs out, and a failure when the program exits first. */
	public function waitUntil(done:() -> Bool, seconds:Float):Bool {
		var deadline = Sys.time() + seconds;
		while (true) {
			drain();
			if (done())
				return true;
			if (process.pollExit() >= 0)
				fail("the watch exited before what the test waited for");
			if (Sys.time() > deadline)
				return false;
			Sys.sleep(0.2);
		}
	}

	/** Waits up to `seconds` for the program to exit and returns its status. */
	public function waitExit(seconds:Float):Int {
		var deadline = Sys.time() + seconds;
		while (true) {
			drain();
			var status = process.pollExit();
			if (status >= 0) {
				drain();
				output.close();
				process.close();
				return status;
			}
			if (Sys.time() > deadline)
				fail('the watch did not exit in $seconds s');
			Sys.sleep(0.2);
		}
	}

	/** Ends the program and everything it started. */
	public function stop():Void {
		drain();
		output.close();
		process.close();
	}

	/** Stops the program and fails the test, showing its log. */
	public function fail(message:String):Void {
		stop();
		Sys.stderr().writeString(content(log));
		smokeFail(message);
	}
}

/** What a finished program wrote to each of its pipes, and its exit status. */
typedef Finished = {status:Int, out:String, err:String};

/** Runs `command` in `cwd` to completion with no shell, as `$(...)` does: its two pipes captured apart. */
/**
 * Runs `command` to its end, with its output collected and, with `echo`, passed through as it comes. A command still
 * running after COMMAND_LIMIT is stopped and fails the test: a program waiting on input, or on a dialog nobody can see,
 * fails with its command line instead of holding the job until it times out.
 */
function execute(command:String, arguments:Array<String>, cwd:String, echo:Bool = false):Finished {
	var process = ChildProcess.spawn(command, arguments, cwd),
		out = new BytesOutput(),
		err = new BytesOutput(),
		buffer = Bytes.alloc(65536),
		open = [true, true],
		deadline = Sys.time() + COMMAND_LIMIT;
	function stopped():Void {
		process.close();
		fail('${[command].concat(arguments).join(" ")} did not finish within $COMMAND_LIMIT s; its output ended with:\n'
			+ lastLines(out.getBytes().toString() + err.getBytes().toString(), 20));
	}
	while (open[0] || open[1]) {
		var moved = false;
		for (index in 0...2) {
			if (!open[index])
				continue;
			var count = index == 0 ? process.readStdout(buffer, 0, buffer.length) : process.readStderr(buffer, 0,
				buffer.length);
			if (count > 0) {
				(index == 0 ? out : err).writeBytes(buffer, 0, count);
				if (echo)
					(index == 0 ? Sys.stdout() : Sys.stderr()).writeBytes(buffer, 0, count);
				moved = true;
			} else if (count == -1)
				open[index] = false;
		}
		if (Sys.time() > deadline)
			stopped();
		if (!moved && (open[0] || open[1]))
			Sys.sleep(0.002);
	}
	var status = process.pollExit();
	while (status < 0) {
		if (Sys.time() > deadline)
			stopped();
		Sys.sleep(0.002);
		status = process.pollExit();
	}
	process.close();
	return {status: status, out: trimEnd(out.getBytes().toString()), err: err.getBytes().toString()};
}

/** Runs `command` with its output passing through, and fails with `what` unless it exits 0. */
function must(what:String, command:String, arguments:Array<String>, cwd:String):Void
	if (execute(command, arguments, cwd, true).status != 0)
		fail(what);

/** As `must`, for a command line given as one array (a headless prefix and the program). */
function mustRun(what:String, commandLine:Array<String>, cwd:String):Void
	must(what, commandLine[0], commandLine.slice(1), cwd);

/** The standard output of `command`, which must exit 0; its standard error passes through. */
function stdout(what:String, command:String, arguments:Array<String>, cwd:String):String {
	var finished = execute(command, arguments, cwd);
	Sys.stderr().writeString(finished.err);
	if (finished.status != 0)
		fail('$what exited with status ${finished.status}: ${finished.out}');
	return finished.out;
}

/** Whether `name` is a program on PATH, as `command -v` answers. */
function onPath(name:String):Bool {
	var path = Sys.getEnv("PATH");
	if (path == null)
		return false;
	for (directory in path.split(WINDOWS ? ";" : ":"))
		if (directory != "" && FileSystem.exists(Path.join([directory, name + SUFFIX])))
			return true;
	return false;
}

/** Calls `visit` for every file under `directory`, which may not exist. */
function walk(directory:String, visit:String->Void):Void {
	if (!FileSystem.isDirectory(directory))
		return;
	for (entry in FileSystem.readDirectory(directory)) {
		var path = Path.join([directory, entry]);
		if (FileSystem.isDirectory(path))
			walk(path, visit);
		else
			visit(path);
	}
}

function content(file:String):String
	return FileSystem.exists(file) ? File.getContent(file) : "";

function lastLines(text:String, count:Int):String {
	var lines = StringTools.replace(text, "\r\n", "\n").split("\n");
	return lines.slice(Std.int(Math.max(0, lines.length - count))).join("\n");
}

function trimEnd(text:String):String {
	while (StringTools.endsWith(text, "\n") || StringTools.endsWith(text, "\r"))
		text = text.substr(0, text.length - 1);
	return text;
}

function seconds(value:Float):String
	return Std.string(Math.round(value * 100) / 100);

/** A directory of its own under the system's temporary directory. */
function scratchDirectory():String {
	var base = Sys.getEnv(WINDOWS ? "TEMP" : "TMPDIR");
	var directory = Path.join([
		base == null || base == "" ? "/tmp" : base,
		'haxeon-release-smoke.${Std.random(0x7fffffff)}'
	]);
	FileSystem.createDirectory(directory);
	// Resolved, so the paths the test runs from are the ones it finds in process command lines: macOS's TMPDIR is under
	// /var, a link to /private/var.
	return FileSystem.fullPath(directory);
}

/** Ends the compiler workers this test started (they idle out, but there is no reason to wait) and removes its directory. */
function cleanup():Void {
	if (!WINDOWS)
		execute("pkill", ["-f", work + "/"], "/");
	execute("cmake", ["-E", "rm", "-rf", work], Path.directory(work));
}

function fail(message:String):Void
	smokeFail(message);

function smokeFail(message:String):Void {
	cleanup();
	Script.fail('release smoke test FAILED: $message');
}
