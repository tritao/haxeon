#!/usr/bin/env haxeon
/**
 * Check published links and match the guides, language tour and migration pages to their examples, as described in
 * docs/DEVELOPMENT.md. Build copies of each project and check its output or open its app for a few frames.
 * `--no-build` checks the pages only. `--errors-only` builds only the error reference examples.
 */
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;
import sys.io.ChildProcess;
import sys.io.File;

private typedef Block = {
	final language:String;
	final info:String;
	final line:Int;
	final lines:Array<String>;
}

private typedef Example = {
	final section:String;
	final slug:String;
	final source:String;
	final relative:String;
}

/** The published sections also determine which pages and examples the suite checks. */
final PUBLISHED = ["guides", "learn", "coming-from", "reference"];

function main() {
	// With `/` on every system, as the links resolved against it are.
	var root = Path.normalize(Path.directory(Path.directory(Script.directory()))),
		failures:Array<String> = [],
		examples:Array<Example> = [],
		pages = 0,
		checked = 0;
	var errorsOnly = Sys.args().indexOf("--errors-only") >= 0;
	for (section in PUBLISHED) {
		var directory = Path.join([root, "docs", section]);
		var names = markdownPages(directory, "");
		names.sort(Reflect.compare);
		if (section == "reference")
			examples = examples.concat(referenceErrorProjects(Path.join([directory, "examples"]), failures));
		else if (!errorsOnly)
			examples = examples.concat(exampleProjects(section, Path.join([directory, "examples"])));
		for (name in names) {
			var page = Path.join([directory, name]),
				text = normalize(File.getContent(page)),
				shown = 'docs/$section/$name';
			checkLinks(root, page, shown, text, failures);
			checkCheckoutPaths(shown, text, failures);
			pages++;
			if (section == "reference" && name == "ERRORS.md")
				checkErrorsPage(root, shown, text, failures);
			if (section == "reference")
				continue;
			if (section == "guides" && name != "README.md" && !~/^[0-9][0-9]-[a-z0-9-]+\.md$/.match(name)) {
				failures.push('$shown: a guide is named NN-slug.md (docs/DEVELOPMENT.md)');
				continue;
			}
			var example = Path.join([directory, "examples", Path.withoutExtension(name)]),
				files = FileSystem.exists(example) ? exampleFiles(example, "") : [];
			for (block in fencedBlocks(text)) {
				var output = block.language == "text" && block.info.indexOf('title="Output"') >= 0;
				if (block.language != "haxe" && block.language != "hx" && block.language != "toml" && !output)
					continue;
				checked++;
				var candidates = output
					? [for (file in files) if (Path.withoutDirectory(file) == "expected-output.txt") file] : files;
				if (candidates.length == 0) {
					failures.push('$shown:${block.line}: no example ${output ? "expected-output.txt" : "file"} under '
						+ 'docs/$section/examples/${Path.withoutExtension(name)}/ to hold this block');
					continue;
				}
				var gap = block.language == "toml" ? "# ..." : output ? null : "// ...", found = false;
				for (file in candidates) {
					var contents = normalize(File.getContent(Path.join([example, file]))).split("\n");
					if (contains(contents, block.lines, gap)) {
						found = true;
						break;
					}
				}
				if (!found)
					failures.push('$shown:${block.line}: this ```${block.info} block is in no file of docs/$section/examples/'
						+ '${Path.withoutExtension(name)}/:\n${block.lines.join("\n")}');
			}
		}
	}
	if (failures.length > 0)
		Script.fail("FAIL: blocks do not match their examples, or links leave the published docs:\n\n"
			+ failures.join("\n\n"));
	var pageSummary = '$checked blocks match their examples and links in $pages published pages pass';
	if (Sys.args().indexOf("--no-build") >= 0) {
		Sys.println('PASS: $pageSummary');
		return;
	}

	var suiteOut = Sys.getEnv("HAXEON_SUITE_OUT"),
		work = Path.join([
			suiteOut == null || suiteOut == "" ? Path.join([root, "out"]) : suiteOut,
			"test-docs-guides"
		]);
	if (FileSystem.exists(work))
		Script.check("cmake", ["-E", "rm", "-rf", work]);
	FileSystem.createDirectory(work);
	var built = 0, rejected = 0;
	for (example in examples) {
		// A copy, so builds write nowhere in the tree; under its own directory name, which names the package.
		var project = Path.join([work, example.section, example.slug, example.relative]);
		copyTree(example.source, project);
		if (example.section == "reference") {
			checkErrorExample(project, example.relative);
			rejected++;
			continue;
		}
		var app = isApp(project);
		Sys.println('== ${example.section}/${example.slug}/${example.relative}');
		if (app) {
			var log = Path.join([project, "create.log"]);
			expectStatus(haxeon(["create", "."], project, log), 0, log, "adding the runner with haxeon create .");
		}
		var log = Path.join([project, "build.log"]);
		expectStatus(haxeon(["build"], project, log), 0, log, '${example.slug}: haxeon build');
		if (app && OWN_FRAME_LOOP.indexOf(example.slug) >= 0)
			drawFor(project);
		else if (app)
			openWindow(project, ["run", "--"], "run");
		else
			runProgram(project);
		switch [example.section, example.slug] {
			case ["guides", "01-first-app"]:
				firstApp(root, project);
			case ["guides", "02-live-editing"]:
				liveEditing(root, Path.join([root, "docs", example.section, "examples", example.slug]), project);
			case ["guides", "03-ui-basics"]:
				uiBasics(Path.join([root, "docs", example.section, "examples", example.slug]), project);
			case ["coming-from", "haxe"]:
				var buildLog = Path.join([project, "release-build.log"]),
					runLog = Path.join([project, "release-run.log"]),
					executable = Path.join([project,
						"build",
						switch Sys.systemName() {
							case "Windows": "windows";
							case "Mac": "macos";
							case _: "linux";
						},
							"bin",
							Sys.systemName() == "Windows" ? "haxe.exe" : "haxe"]);
				expectStatus(haxeon(["build", "--build-mode", "release"], project, buildLog), 0, buildLog,
					"building the Haxe migration example in release mode");
				expectStatus(Script.run(executable, [], {cwd: project, log: runLog}), 0, runLog,
					"running the Haxe migration example's executable");
				if (normalize(content(runLog)) != normalize(content(Path.join([project, "expected-output.txt"]))))
					Script.fail('FAIL: the Haxe migration executable printed:\n${File.getContent(runLog)}');
			case ["guides", "05-shipping"]:
				shipping(project);
			case _:
		}
		built++;
	}
	Sys.println('PASS: $pageSummary, $built example projects build and run, and $rejected fail with their expected code');
}

/** "Your first app": the manifest is the one `haxeon create my_app` writes, and the release build runs on its own. */
function firstApp(root:String, project:String):Void {
	var fresh = Path.join([Path.directory(project), "fresh"]), log = Path.join([project, "fresh.log"]);
	FileSystem.createDirectory(fresh);
	expectStatus(haxeon(["create", "my_app"], fresh, log), 0, log,
		"haxeon create my_app");
	if (File.getContent(Path.join([fresh, "my_app", "haxeon.toml"])) != File.getContent(Path.join([
		project,
		"haxeon.toml"
	])))
		Script.fail("FAIL: docs/guides/examples/01-first-app/my_app/haxeon.toml is not the manifest haxeon create my_app writes; "
			+ "update the example and the guide");
	if (hasXvfb()) {
		var executable = appFiles(Path.join([project, "build", PLATFORM, "app"])).executable;
		log = Path.join([project, "idle-frames.log"]);
		var idle = Script.run("xvfb-run", ["-a", "timeout", "20", executable, "--frames=10"], {cwd: project, log: log});
		// A hang leaves an empty log, so the log becomes a second run under gdb showing where each thread waits.
		if (idle == 124 && Script.run("sh", ["-c", "command -v gdb >/dev/null"]) == 0)
			Script.run("xvfb-run", [
				"-a", "timeout", "-s", "INT", "20", "gdb", "-batch", "-ex",
				"handle SIGSEGV SIGBUS SIGFPE SIGPIPE nostop noprint pass",
				"-ex", "run", "-ex", "thread apply all bt", "--args", executable, "--frames=10"
			], {
				cwd: project,
				log: log
			});
		expectStatus(idle, 0, log, "running an idle window for ten frames without capture");

		if (Script.run("sh", ["-c", "command -v xmessage && command -v xwininfo"], {log: log}) == 0) {
			log = Path.join([project, "capture-window.log"]);
			var capture = Path.join([project, "capture-window"]);
			var decoy = "xmessage -title 'My App' -geometry 173x129+850+320 decoy & pid=$!\n"
				+ "trap 'kill $pid' EXIT\n"
				+ "for i in {1..50}; do xwininfo -name 'My App' >/dev/null 2>&1 && break; sleep 0.1; done\n"
				+ "xwininfo -name 'My App' >/dev/null || exit 1\n"
				+ 'timeout 20 "$1" --frames=10 "$2"';
			expectStatus(Script.run("xvfb-run", ["-a", "bash", "-c", decoy, "_", executable, '--capture=$capture'],
				{cwd: project, log: log}), 0, log, "capturing the app with a same-title window already open");
			var reference = File.getBytes(Path.join([project, "capture-run", "frame.png"]));
			var actual = File.getBytes(Path.join([capture, "frame.png"]));
			// A PNG's IHDR stores its width and height immediately after the chunk type.
			if (actual.sub(16, 8).compare(reference.sub(16, 8)) != 0)
				Script.fail("FAIL: capture dimensions changed when a same-title window was open");
		}
	}
	log = Path.join([project, "release.log"]);
	expectStatus(haxeon(["build", "--build-mode=release"], project, log), 0, log, "haxeon build --build-mode=release");
	var built = appFiles(Path.join([project, "build", PLATFORM, "app"]));
	if (!FileSystem.exists(built.executable) || FileSystem.exists(built.module))
		Script.fail('FAIL: the release build did not leave ${built.executable} alone, without a module beside it');
	openWindow(project, [], "release", built.executable);
}

/**
 * "UI basics": the reader's clicks and typing, played from the example's input/ scripts, change the app's state as the guide
 * says. Each script `NAME.json` ends in the state the app reports (`diagnosticState`) listed for it here.
 */
function uiBasics(example:String, project:String):Void {
	var expected:Map<String, String> = [
		// Select the second task, type a title in the form and click Add: the new task is added and selected.
			"add-task" => '{"tasks":4,"selected":3,"tab":"tasks","dark":false}',
			// Tick Done, open the Settings tab and turn on the dark theme.
			"dark-theme" => '{"tasks":3,"selected":0,"tab":"settings","dark":true}'
		];
	for (name => state in expected) {
		var script = Path.join([example, "input", '$name.json']),
			capture = Path.join([project, 'capture-$name']),
			log = Path.join([project, '$name.log']),
			command = [
				Script.haxeon(),
				"run",
				"--",
				"--capture-seconds=5",
				'--capture=$capture',
				'--input-script=$script'
			];
		var status = hasXvfb() ? Script.run("xvfb-run", ["-a"].concat(command),
			{cwd: project, log: log}) : Script.run(command[0], command.slice(1), {
				cwd: project,
				log: log
			});
		expectStatus(status, 0, log, 'running the task list with input/$name.json');
		var text = content(Path.join([capture, "app-state.json"])), wanted:Dynamic = haxe.Json.parse(state);
		var reported:Dynamic = text == "" ? {} : haxe.Json.parse(text);
		for (field in Reflect.fields(wanted))
			if (Std.string(Reflect.field(reported, field)) != Std.string(Reflect.field(wanted, field)))
				Script.fail('FAIL: after input/$name.json the task list reports $text, expected $state; its log:\n${content(log)}');
	}
}

/**
 * "Shipping": the release build is one executable with the packages' libraries beside it and no module, the directory the
 * guide archives with tar runs from wherever it is unpacked, and a release build refuses to be watched.
 */
function shipping(project:String):Void {
	var log = Path.join([project, "release.log"]);
	expectStatus(haxeon(["build", "--build-mode=release"], project, log), 0, log, "haxeon build --build-mode=release");
	var built = appFiles(Path.join([project, "build", PLATFORM, "app"]));
	if (!FileSystem.exists(built.executable) || FileSystem.exists(built.module))
		Script.fail('FAIL: the release build did not leave ${built.executable} alone, without a module beside it');
	// The app directory, archived as the guide does on Linux, runs from wherever it is unpacked (a bundle's libraries are in it).
	var archive = Path.join([project, 'my_app-$PLATFORM.tar.gz']),
		unpacked = Path.join([Path.directory(project), "unpacked"]);
	Script.check("tar", ["-czf", archive, "-C", Path.join([project, "build", PLATFORM]), "app"]);
	FileSystem.createDirectory(unpacked);
	Script.check("tar", ["-xzf", archive, "-C", unpacked]);
	openWindow(project, [], "unpacked", appFiles(Path.join([unpacked, "app"])).executable);
	log = Path.join([project, "release-watch.log"]);
	expectStatus(haxeon(["run", "--build-mode=release", "--watch"], project, log), 2, log,
		"haxeon run --build-mode=release --watch");
}

/**
 * "Live editing": the app starts as "Your first app" left it, runs under `haxeon run --watch` (its entry class has the
 * live entry points, so the watch patches it), and takes the guide's
 * edits in order, each a version of src/Main.hx in the example's steps/ whose name says what it does: `-patch` patches the
 * running app, `-reload` reloads its module, `-error` fails the build while the app runs on.
 */
function liveEditing(root:String, example:String, project:String):Void {
	var main = Path.join([project, "src", "Main.hx"]), original = File.getContent(main);
	if (original != File.getContent(Path.join([root, "docs/guides/examples/01-first-app/my_app/src/Main.hx"])))
		Script.fail("FAIL: the live editing example does not start from the app Your first app ends with");
	var events = Path.join([project, "build", "host", "main.hl.watch-events.jsonl"]),
		log = Path.join([project, "live.log"]),
		headless = hasXvfb() ? ["xvfb-run", "-a"] : [];
	// The watch's output goes to a file, so nothing has to drain its pipes; closing the process ends its process group.
	var watch = ChildProcess.spawn("sh", ["-c", 'exec "$$@" > "$log" 2>&1', "sh"].concat(headless)
		.concat([Script.haxeon(), "run", "--watch"]), project);
	var steps = [for (name in FileSystem.readDirectory(Path.join([example, "steps"]))) name];
	steps.sort(Reflect.compare);
	waitFor(watch, log, () -> content(log).indexOf("haxeon: running") >= 0, 900, "the app to start");
	for (index in 0...steps.length) {
		var step = steps[index],
			expected = StringTools.endsWith(step, "-patch") ? '"kind":"patch-applied"' : StringTools.endsWith(step,
				"-reload") ? "reloaded the module" : StringTools.endsWith(step, "-error")
				? '"kind":"build-failed"' : null;
		if (expected == null)
			stop(watch, 'FAIL: steps/$step must end in -patch, -reload or -error, which says what the edit does');
		var edit = File.getContent(Path.join([example, "steps", step, "Main.hx"])), applied = false, attempt = 0;
		// An edit the host sees before it has loaded the app is no patch but the module it loads. The first edit goes back and
		// forth until one patches: from then on the host runs the app.
		while (!applied) {
			var before = lines(events).length;
			File.saveContent(main, edit);
			applied = waitFor(watch, log, () -> {
				var added = lines(events).slice(before);
				for (line in added)
					if (line.indexOf(expected) >= 0)
						return true;
				for (line in added)
					if (line.indexOf('"kind":"patch-rejected"') >= 0
						|| (expected != '"kind":"build-failed"' && line.indexOf('"kind":"build-failed"') >= 0)
						|| (StringTools.endsWith(step, "-patch") && line.indexOf('"kind":"reload"') >= 0))
						stop(watch,
							'FAIL: steps/$step: expected $expected, got $line; the watch log:\n${content(log)}');
				return false;
			}, index == 0 ? 60 : 300, 'steps/$step to be applied ($expected)', index == 0 && attempt < 4);
			if (!applied) {
				attempt++;
				before = lines(events).length;
				File.saveContent(main, original);
				waitFor(watch, log,
					() -> lines(events).slice(before).filter(line -> line.indexOf('"kind":"build-ok"') >= 0)
					.length > 0, 300, "the first version to build again");
				Sys.sleep(2);
			}
		}
		Sys.println('ok: steps/$step');
	}
	stop(watch, null);
	// What the guide shows the terminal printing, but the revision numbers, which a retried first edit moves.
	for (text in [
		"haxeon: source changed; rebuilding Haxe code",
		"haxeon: patched live module to revision ",
		"(the build requires a reload: global_layout_changed Main.step); reloading module",
		"haxeon: reloaded live module to revision ",
		'error[E1005]: Unknown static field "Main.stpe"',
		"haxeon: build failed; keeping the current app open"
	])
		if (content(log).indexOf(text) < 0)
			Script.fail('FAIL: the live session did not print "$text", which docs/guides/02-live-editing.md shows; its log:\n'
				+ content(log));
}

/**
 * Waits up to `seconds` for `done`, while the watch runs; false on time out when `mayTimeOut`, else the test fails, as it does
 * when the watch exits.
 */
function waitFor(watch:ChildProcess, log:String, done:() -> Bool, seconds:Float, what:String,
		mayTimeOut:Bool = false):Bool {
	var deadline = Sys.time() + seconds;
	while (!done()) {
		if (watch.pollExit() >= 0)
			stop(watch, 'FAIL: the watch exited while waiting for $what; its log:\n${content(log)}');
		if (Sys.time() > deadline) {
			if (mayTimeOut)
				return false;
			stop(watch, 'FAIL: waited $seconds s for $what; the watch log:\n${content(log)}');
		}
		Sys.sleep(0.2);
	}
	return true;
}

/** Ends the watch, its app and its xvfb-run, and with `failure` the test. */
function stop(watch:ChildProcess, failure:Null<String>):Void {
	watch.close();
	if (failure != null)
		Script.fail(failure);
}

/** Runs the app (`haxeon` with `arguments`, or `executable`) for ten frames with a capture, headless where it can be. */
function openWindow(project:String, arguments:Array<String>, name:String, ?executable:String):Void {
	var capture = Path.join([project, 'capture-$name']),
		log = Path.join([project, '$name.log']),
		command = (executable == null ? [Script.haxeon()].concat(arguments) : [executable]).concat([
			"--frames=10",
			'--capture=$capture'
		]);
	var status = hasXvfb() ? Script.run("xvfb-run", ["-a"].concat(command),
		{cwd: project, log: log}) : Script.run(command[0],
		command.slice(1), {cwd: project, log: log});
	expectStatus(status, 0, log, 'running ${Path.withoutDirectory(project)} ($name) for ten frames');
	// The frames it rendered, and on Linux the window's image, which ImageMagick's import takes from the X server.
	var metrics = content(Path.join([capture, "frame-metrics.json"])),
		rendered:Null<Int> = metrics == "" ? null : haxe.Json.parse(metrics).renderedFrames;
	if (rendered == null || rendered < 1)
		Script.fail('FAIL: ${Path.withoutDirectory(project)} ($name) rendered no frame; its log:\n${File.getContent(log)}');
	if (PLATFORM == "linux" && !FileSystem.exists(Path.join([capture, "frame.png"])))
		Script.fail('FAIL: ${Path.withoutDirectory(project)} ($name) wrote no frame.png; its log:\n${File.getContent(log)}');
}

/**
 * Guides whose apps run their own frame loop through Runtime.launch instead of the UI host, so they take no `--frames`
 * or `--capture`: each runs for a few seconds and passes if it is still drawing when the time is up.
 */
final OWN_FRAME_LOOP = ["06-gpu-basics"];

function drawFor(project:String):Void {
	var log = Path.join([project, "run.log"]), seconds = "8";
	var command = [Script.haxeon(), "run"];
	var status = hasXvfb() ? Script.run("xvfb-run", ["-a", "timeout", seconds].concat(command),
		{cwd: project, log: log}) : Script.run("timeout", [seconds].concat(command), {
			cwd: project,
			log: log
		});
	if (status != 124)
		Script.fail('FAIL: ${Path.withoutDirectory(project)} stopped with status $status within ${seconds}s; its log:\n'
			+ File.getContent(log));
}

/** This machine's platform, as `[app].platforms` and the runners name it. */
final PLATFORM = switch Sys.systemName() {
	case "Windows": "windows";
	case "Mac": "macos";
	case _: "linux";
};

/** Where a runner's build in `directory` (its app/) puts my_app's executable and module: in a bundle on macOS. */
function appFiles(directory:String):{executable:String, module:String} {
	return switch PLATFORM {
		case "windows": {executable: Path.join([directory, "my_app.exe"]), module: Path.join([directory, "my_app.hl"])};
		case "macos": {
			executable: Path.join([directory, "my_app.app", "Contents", "MacOS", "my_app"]),
			module: Path.join([directory, "my_app.app", "Contents", "Resources", "my_app.hl"])
		};
		case _: {executable: Path.join([directory, "my_app"]), module: Path.join([directory, "my_app.hl"])};
	};
}

/** A program runs, and prints its `expected-output.txt` when it has one. */
function runProgram(project:String):Void {
	var expected = Path.join([project, "expected-output.txt"]);
	if (!FileSystem.exists(expected))
		return;
	var log = Path.join([project, "run.log"]);
	expectStatus(haxeon(["run", "--quiet"], project, log), 0, log, 'running ${Path.withoutDirectory(project)}');
	if (normalize(File.getContent(log)) != normalize(File.getContent(expected)))
		Script.fail('FAIL: ${Path.withoutDirectory(project)} printed:\n${File.getContent(log)}\nand its expected-output.txt holds:\n'
			+ File.getContent(expected));
}

/** The section's pages, in subdirectories too, by path relative to it; example projects are not pages. */
function markdownPages(directory:String, relative:String):Array<String> {
	var result:Array<String> = [];
	for (name in FileSystem.readDirectory(Path.join([directory, relative]))) {
		var path = relative == "" ? name : '$relative/$name';
		if (FileSystem.isDirectory(Path.join([directory, path]))) {
			if (name != "examples")
				result = result.concat(markdownPages(directory, path));
		} else if (StringTools.endsWith(name, ".md"))
			result.push(path);
	}
	result.sort(Reflect.compare);
	return result;
}

/**
 * Published pages are read by people with a release, not a checkout: they name the installed `haxeon`, and never the
 * checkout's scripts, tools, sources, tests, vendored code or unpublished documentation.
 */
function checkCheckoutPaths(shown:String, text:String, failures:Array<String>):Void {
	var checkout =
		~/scripts[\/\\]haxeon|scripts\/[a-z0-9-]+\.(sh|py|ps1|cmd)|\bvendor\/|docs\/(design|internals|reports|adr)\/|\btests\/(integration|programs|runtime|tooling|native|fixtures|compiler)\/|\bsrc\/(compiler|tools|build|editor)\/|\.tools\/|\bout\/(sdk|tools)\//;
	var lines = text.split("\n");
	for (index in 0...lines.length)
		if (checkout.match(lines[index]))
			failures.push('$shown:${index + 1}: "${checkout.matched(0)}" points into a Haxeon checkout; published pages describe a release');
}

/**
 * The error reference has one `## CODE: title` section per DiagnosticCode, in code order, and a section's Haxe block is
 * the whole `src/Main.hx` of that code's example project, which must fail with that code.
 */
function checkErrorsPage(root:String, shown:String, text:String, failures:Array<String>):Void {
	var registry = content(Path.join([root, "src/compiler/core/DiagnosticCode.hx"])),
		value = ~/= "([EW][0-9]{4})";/,
		codes:Array<String> = [];
	while (value.match(registry)) {
		codes.push(value.matched(1));
		registry = value.matchedRight();
	}
	codes.sort(Reflect.compare);
	var sections = text.split("\n## "), documented:Array<String> = [], heading = ~/^([EW][0-9]{4}): \S/;
	for (section in sections.slice(1)) {
		if (!heading.match(section)) {
			failures.push('$shown: a section is headed "## CODE: title", not "## ${section.split("\n")[0]}"');
			continue;
		}
		var code = heading.matched(1);
		documented.push(code);
		var example = Path.join([root, "docs/reference/examples/errors", code, "src/Main.hx"]),
			blocks = [for (block in fencedBlocks(section)) if (block.language == "haxe") block];
		if (blocks.length > 1)
			failures.push('$shown: $code shows more than one Haxe block');
		else if (blocks.length == 1 && !FileSystem.exists(example))
			failures.push('$shown: $code shows a program, but docs/reference/examples/errors/$code/src/Main.hx does not exist');
		else if (blocks.length == 1 && blocks[0].lines.join("\n") != StringTools.rtrim(normalize(content(example))))
			failures.push('$shown: $code shows a program that differs from docs/reference/examples/errors/$code/src/Main.hx');
		else if (blocks.length == 0 && FileSystem.exists(example))
			failures.push('$shown: $code has an example project but does not show its src/Main.hx');
	}
	if (documented.join(",") != codes.join(","))
		failures.push('$shown: its sections must be the codes in src/compiler/core/DiagnosticCode.hx, in order; documented '
			+ documented.join(" ") + ', defined ' + codes.join(" "));
}

/** The projects under docs/reference/examples/errors, one per code, each holding its code in expected-error.txt. */
function referenceErrorProjects(examples:String, failures:Array<String>):Array<Example> {
	var projects = exampleProjects("reference", examples, "errors");
	var root = Path.join([examples, "errors"]);
	var codes = [for (name in FileSystem.readDirectory(root))
		if (FileSystem.isDirectory(Path.join([root, name]))) name];
	for (code in codes) {
		var project = Path.join([root, code]);
		var source = Path.join([project, "src/Main.hx"]);
		if (!~/^E[0-9]{4}$/.match(code) || !FileSystem.exists(Path.join([project, "haxeon.toml"]))
			|| StringTools.trim(content(source)) == "" || StringTools.trim(content(Path.join([
				project,
				"expected-error.txt"
			]))) != code)
			failures.push('docs/reference/examples/errors/$code must contain haxeon.toml, src/Main.hx, and its code in expected-error.txt');
	}
	return projects;
}

/** A failed build must print exactly one diagnostic, with the code named by the example. */
function checkErrorExample(project:String, code:String):Void {
	var expected = StringTools.trim(content(Path.join([project, "expected-error.txt"])));
	var log = Path.join([project, "build.log"]);
	var status = haxeon(["build", "--color=never", "--diagnostic-format=short"], project, log);
	var location = ~/^.+:[0-9]+:[0-9]+: ([EW][0-9]{4}): /;
	var actual = [for (line in lines(log)) if (location.match(line)) location.matched(1)];
	if (status == 0 || actual.length != 1 || actual[0] != expected)
		Script.fail('FAIL: $code expected one diagnostic ($expected) and a failed build; exit $status, log:\n${content(log)}');
}

/** Each project under a section's `examples` directory, grouped by page; a project's local dependencies are its own. */
function exampleProjects(section:String, examples:String, ?only:String):Array<Example> {
	var result:Array<Example> = [];
	var slugs = [for (name in FileSystem.readDirectory(examples))
		if ((only == null || name == only) && FileSystem.isDirectory(Path.join([examples, name]))) name];
	slugs.sort(Reflect.compare);
	for (slug in slugs) {
		var manifests = [
			for (file in exampleFiles(Path.join([examples, slug]), ""))
				if (Path.withoutDirectory(file) == "haxeon.toml") Path.directory(file)
		];
		for (directory in manifests) {
			// A manifest inside another example's directory is that example's local dependency, not an example of its own.
			var nested = Lambda.exists(manifests, outer -> outer != directory
				&& StringTools.startsWith(directory, outer == "" ? "" : outer + "/"));
			if (!nested)
				result.push({
					section: section,
					slug: slug,
					source: Path.join([examples, slug, directory]),
					relative: directory
				});
		}
	}
	return result;
}

/** The files under `directory`, relative to it with `/`, sorted. */
function exampleFiles(directory:String, prefix:String):Array<String> {
	var result:Array<String> = [];
	var names = FileSystem.readDirectory(Path.join([directory, prefix]));
	names.sort(Reflect.compare);
	for (name in names) {
		var relative = prefix == "" ? name : '$prefix/$name';
		if (FileSystem.isDirectory(Path.join([directory, relative]))) {
			// What a build of an example left there, were one built in place.
			if (name != "build")
				result = result.concat(exampleFiles(directory, relative));
		} else
			result.push(relative);
	}
	return result;
}

/** The fenced code blocks of a Markdown page, their lines without the fence's indentation. */
function fencedBlocks(text:String):Array<Block> {
	var result:Array<Block> = [], lines = text.split("\n"), index = 0;
	var opening = ~/^( {0,3})(```+|~~~+)\s*([^\s`]*)(.*)$/;
	while (index < lines.length) {
		if (!opening.match(lines[index])) {
			index++;
			continue;
		}
		var indent = opening.matched(1).length,
			fence = opening.matched(2),
			language = opening.matched(3).toLowerCase(),
			info = StringTools.trim(opening.matched(3) + opening.matched(4)),
			start = index + 1,
			body:Array<String> = [];
		index++;
		while (index < lines.length) {
			var trimmed = StringTools.trim(lines[index]);
			if (StringTools.startsWith(trimmed, fence)
				&& StringTools.trim(StringTools.replace(trimmed, fence.charAt(0), "")) == "")
				break;
			var line = lines[index], cut = 0;
			while (cut < indent && cut < line.length && line.charAt(cut) == " ")
				cut++;
			body.push(line.substr(cut));
			index++;
		}
		index++;
		result.push({
			language: language,
			info: info,
			line: start,
			lines: dedent(trimBlank(body))
		});
	}
	return result;
}

/**
 * Whether `block` appears in `file`: each part between `gap` lines as consecutive lines, after the common indentation of
 * both, and the parts in order.
 */
function contains(file:Array<String>, block:Array<String>, gap:Null<String>):Bool {
	var parts:Array<Array<String>> = [[]];
	for (line in block)
		if (gap != null && StringTools.trim(line) == gap)
			parts.push([]);
		else
			parts[parts.length - 1].push(line);
	var from = 0;
	for (part in parts) {
		var wanted = dedent(trimBlank(part));
		if (wanted.length == 0)
			continue;
		var at = find(file, wanted, from);
		if (at < 0)
			return false;
		from = at + wanted.length;
	}
	return true;
}

function find(file:Array<String>, wanted:Array<String>, from:Int):Int {
	var first = StringTools.trim(wanted[0]), last = file.length - wanted.length;
	var index = from;
	while (index <= last) {
		if (StringTools.trim(file[index]) == first) {
			var window = dedent(file.slice(index, index + wanted.length)), same = true;
			for (offset in 0...wanted.length)
				if (window[offset] != wanted[offset]) {
					same = false;
					break;
				}
			if (same)
				return index;
		}
		index++;
	}
	return -1;
}

/** The lines without the leading whitespace all non-blank ones share, and without trailing whitespace. */
function dedent(lines:Array<String>):Array<String> {
	var trimmed = [for (line in lines) StringTools.rtrim(line)], common:Null<String> = null;
	for (line in trimmed) {
		if (line == "")
			continue;
		var end = 0;
		while (end < line.length && (line.charAt(end) == " " || line.charAt(end) == "\t"))
			end++;
		var lead = line.substr(0, end);
		if (common == null)
			common = lead;
		else {
			var shared = 0;
			while (shared < common.length && shared < lead.length && common.charAt(shared) == lead.charAt(shared))
				shared++;
			common = common.substr(0, shared);
		}
	}
	var cut = common == null ? 0 : common.length;
	return [for (line in trimmed) line == "" ? "" : line.substr(cut)];
}

function trimBlank(lines:Array<String>):Array<String> {
	var start = 0, end = lines.length;
	while (start < end && StringTools.trim(lines[start]) == "")
		start++;
	while (end > start && StringTools.trim(lines[end - 1]) == "")
		end--;
	return lines.slice(start, end);
}

/** Links outside fenced blocks: each relative one must exist and stay in what the site publishes. */
function checkLinks(root:String, page:String, shown:String, text:String, failures:Array<String>):Void {
	var prose = new StringBuf(), inFence = false, fence = "";
	for (line in text.split("\n")) {
		var trimmed = StringTools.trim(line);
		if (!inFence && (StringTools.startsWith(trimmed, "```") || StringTools.startsWith(trimmed, "~~~"))) {
			inFence = true;
			fence = trimmed.substr(0, 3);
			continue;
		}
		if (inFence) {
			if (StringTools.startsWith(trimmed, fence))
				inFence = false;
			continue;
		}
		prose.add(line + "\n");
	}
	var targets:Array<String> = [], body = prose.toString();
	var inlineLink = ~/\]\(\s*<?([^)\s>]+)>?(\s+"[^"]*")?\s*\)/;
	var rest = body;
	while (inlineLink.match(rest)) {
		targets.push(inlineLink.matched(1));
		rest = inlineLink.matchedRight();
	}
	var definition = ~/^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?/;
	for (line in body.split("\n"))
		if (definition.match(line))
			targets.push(definition.matched(1));
	for (target in targets) {
		if (~/^[a-z][a-z0-9+.-]*:/i.match(target) || StringTools.startsWith(target, "#"))
			continue;
		var path = target.split("#")[0];
		var resolved = Path.normalize(Path.join([Path.directory(page), path])),
			relative = resolved.substr(root.length + 1);
		var published = false;
		for (section in PUBLISHED)
			if (StringTools.startsWith(relative
				+ (FileSystem.exists(resolved) && FileSystem.isDirectory(resolved) ? "/" : ""),
				'docs/$section/'))
				published = true;
		if (!StringTools.startsWith(resolved, root + "/") || !published)
			failures.push('$shown: links to $target, outside the published docs');
		else if (!FileSystem.exists(resolved))
			failures.push('$shown: links to $target, which does not exist');
	}
}

function copyTree(source:String, target:String):Void {
	FileSystem.createDirectory(target);
	for (name in FileSystem.readDirectory(source)) {
		var from = Path.join([source, name]), to = Path.join([target, name]);
		if (FileSystem.isDirectory(from)) {
			if (name != "build")
				copyTree(from, to);
		} else
			File.copy(from, to);
	}
}

function isApp(project:String):Bool {
	for (line in normalize(File.getContent(Path.join([project, "haxeon.toml"]))).split("\n"))
		if (StringTools.trim(line) == "[app]")
			return true;
	return false;
}

function hasXvfb():Bool
	return Sys.systemName() == "Linux" && Script.run("sh", ["-c", "command -v xvfb-run >/dev/null"]) == 0;

function haxeon(arguments:Array<String>, directory:String, log:String):Int
	return Script.run(Script.haxeon(), arguments, {cwd: directory, log: log});

function expectStatus(status:Int, expected:Int, log:String, what:String):Void
	if (status != expected)
		Script.fail('FAIL: $what exited with $status, expected $expected; its log:\n${content(log)}');

function lines(file:String):Array<String>
	return FileSystem.exists(file)
		? [for (line in normalize(File.getContent(file)).split("\n")) if (line != "") line] : [];

function content(file:String):String
	return FileSystem.exists(file) ? File.getContent(file) : "";

function normalize(text:String):String
	return StringTools.replace(text, "\r\n", "\n");
