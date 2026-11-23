#!/usr/bin/env haxeon
/**
 * The guides in docs/guides, as docs/guides/README.md lays them out: every ```haxe and ```toml block of `NN-slug.md` appears,
 * line for line after its common indentation, in a file of `examples/NN-slug/` (a `// ...` or `# ...` line skips lines), a
 * ```text title="Output" block in an `expected-output.txt` there, and a page links only to guides, reference pages and URLs.
 * Then each example project, copied out of the tree, builds with this checkout's haxeon: a program with an
 * `expected-output.txt` runs and prints it, and an app (Linux only, where the app template has its runner) gets its runner from
 * `haxeon create .`, builds and opens its window for a few frames, under xvfb-run when there is one. "Your first app" also
 * builds its app ahead of time and runs that, and "Live editing" runs its app under `run --watch --live` and makes the edits
 * the guide makes. `--no-build` checks the pages only.
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
	final slug:String;
	final source:String;
	final relative:String;
}

/** Where a guide may link: other guides (and their examples) and reference pages, which the site publishes. */
final PUBLISHED = ["docs/guides/", "docs/reference/"];

function main() {
	// With `/` on every system, as the links resolved against it are.
	var root = Path.normalize(Path.directory(Path.directory(Script.directory()))),
		guides = Path.join([root, "docs", "guides"]),
		failures:Array<String> = [];
	var pages = [for (name in FileSystem.readDirectory(guides)) if (StringTools.endsWith(name, ".md")) name];
	pages.sort(Reflect.compare);
	var checked = 0;
	for (name in pages) {
		var page = Path.join([guides, name]), text = normalize(File.getContent(page)), shown = 'docs/guides/$name';
		checkLinks(root, page, shown, text, failures);
		if (name == "README.md")
			continue;
		if (!~/^[0-9][0-9]-[a-z0-9-]+\.md$/.match(name)) {
			failures.push('$shown: a guide is named NN-slug.md (docs/guides/README.md)');
			continue;
		}
		var example = Path.join([guides, "examples", Path.withoutExtension(name)]),
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
					+ 'docs/guides/examples/${Path.withoutExtension(name)}/ to hold this block');
				continue;
			}
			var gap = block.language == "toml" ? "# ..." : output ? null : "// ...", found = false;
			for (file in candidates)
				if (contains(normalize(File.getContent(Path.join([example, file]))).split("\n"), block.lines, gap)) {
					found = true;
					break;
				}
			if (!found)
				failures.push('$shown:${block.line}: this ```${block.info} block is in no file of docs/guides/examples/'
					+ '${Path.withoutExtension(name)}/:\n${block.lines.join("\n")}');
		}
	}
	if (failures.length > 0)
		Script.fail("FAIL: the guides do not match their examples or link outside what the site publishes:\n\n"
			+ failures.join("\n\n"));
	if (Sys.args().indexOf("--no-build") >= 0) {
		Sys.println('PASS: $checked code blocks of ${pages.length - 1} guides are in their examples, and the links stay in what the site publishes');
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
	var built = 0;
	for (example in exampleProjects(Path.join([guides, "examples"]))) {
		// A copy, so builds write nowhere in the tree; under its own directory name, which names the package.
		var project = Path.join([work, example.slug, example.relative]);
		copyTree(example.source, project);
		var app = isApp(project);
		if (app && Sys.systemName() != "Linux") {
			Sys.println('skip: ${example.slug}/${example.relative} is an app, and the app template has a runner for Linux only');
			continue;
		}
		Sys.println('== ${example.slug}/${example.relative}');
		if (app) {
			var log = Path.join([project, "create.log"]);
			expectStatus(haxeon(["create", "."], project, log), 0, log, "adding the runner with haxeon create .");
		}
		var log = Path.join([project, "build.log"]);
		expectStatus(haxeon(["build"], project, log), 0, log, '${example.slug}: haxeon build');
		if (app)
			openWindow(project, ["run", "--"], "run");
		else
			runProgram(project);
		switch example.slug {
			case "01-first-app":
				firstApp(root, project);
			case "02-live-editing":
				liveEditing(root, Path.join([guides, "examples", example.slug]), project);
			case _:
		}
		built++;
	}
	Sys.println('PASS: $checked code blocks of ${pages.length - 1} guides are in their examples, the links stay in what the site publishes, and $built example projects build and run');
}

/** "Your first app": the manifest is the one `haxeon create my_app` writes, and the release build runs on its own. */
function firstApp(root:String, project:String):Void {
	var fresh = Path.join([Path.directory(project), "fresh"]), log = Path.join([project, "fresh.log"]);
	FileSystem.createDirectory(fresh);
	expectStatus(haxeon(["create", "my_app"], fresh, log), 0, log, "haxeon create my_app");
	if (File.getContent(Path.join([fresh, "my_app", "haxeon.toml"])) != File.getContent(Path.join([
		project,
		"haxeon.toml"
	])))
		Script.fail("FAIL: docs/guides/examples/01-first-app/my_app/haxeon.toml is not the manifest haxeon create my_app writes; "
			+ "update the example and the guide");
	log = Path.join([project, "release.log"]);
	expectStatus(haxeon(["build", "--build-mode=release"], project, log), 0, log, "haxeon build --build-mode=release");
	var executable = Path.join([project, "build", "linux", "app", "my_app"]);
	if (!FileSystem.exists(executable) || FileSystem.exists(executable + ".hl"))
		Script.fail('FAIL: the release build did not leave $executable alone, without a module beside it');
	openWindow(project, [], "release", executable);
}

/**
 * "Live editing": the app starts as "Your first app" left it, runs under `haxeon run --watch --live`, and takes the guide's
 * edits in order, each a version of src/Main.hx in the example's steps/ whose name says what it does: `-patch` patches the
 * running app, `-reload` reloads its module, `-error` fails the build while the app runs on.
 */
function liveEditing(root:String, example:String, project:String):Void {
	var main = Path.join([project, "src", "Main.hx"]), original = File.getContent(main);
	if (original != File.getContent(Path.join([root, "docs/guides/examples/01-first-app/my_app/src/Main.hx"])))
		Script.fail("FAIL: the live editing example does not start from the app Your first app ends with");
	var events = Path.join([project, "build", "host", "main.hl.watch-events.jsonl"]),
		liveState = Path.join([project, "build", "host", "main.hl.live.state"]),
		appliedAt = 0.0,
		log = Path.join([project, "live.log"]),
		headless = hasXvfb() ? ["xvfb-run", "-a"] : [];
	// The watch's output goes to a file, so nothing has to drain its pipes; closing the process ends its process group.
	var watch = ChildProcess.spawn("sh", ["-c", 'exec "$$@" > "$log" 2>&1', "sh"].concat(headless)
		.concat([Script.haxeon(), "run", "--watch", "--live"]), project);
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
		// A failed build ends the compile server's session, and the next build resumes the running module from the history the
		// server records once a publication has had no request after it for a while (`CompilerServer.LIVE_STATE_DELAY_SECONDS`).
		// A reader looks at the window between edits, so the typo comes after that; a fix saved sooner reloads.
		if (StringTools.endsWith(step, "-error"))
			waitFor(watch, log, () -> FileSystem.exists(liveState)
				&& FileSystem.stat(liveState).mtime.getTime() / 1000 >= appliedAt - 1, 120,
				"the compile server to record the live module's history");
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
		appliedAt = Sys.time();
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
	if (!FileSystem.exists(Path.join([capture, "frame.png"])))
		Script.fail('FAIL: ${Path.withoutDirectory(project)} ($name) wrote no frame.png; its log:\n${File.getContent(log)}');
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

/** Each project under `examples` (a directory with a haxeon.toml), by guide. */
function exampleProjects(examples:String):Array<Example> {
	var result:Array<Example> = [];
	var slugs = [for (name in FileSystem.readDirectory(examples))
		if (FileSystem.isDirectory(Path.join([examples, name]))) name];
	slugs.sort(Reflect.compare);
	for (slug in slugs)
		for (file in exampleFiles(Path.join([examples, slug]), ""))
			if (Path.withoutDirectory(file) == "haxeon.toml")
				result.push({
					slug: slug,
					source: Path.join([examples, slug, Path.directory(file)]),
					relative: Path.directory(file)
				});
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
		for (prefix in PUBLISHED)
			if (StringTools.startsWith(relative
				+ (FileSystem.exists(resolved) && FileSystem.isDirectory(resolved) ? "/" : ""),
				prefix))
				published = true;
		if (!StringTools.startsWith(resolved, root + "/") || !published)
			failures.push('$shown: links to $target, outside the guides and the reference pages the site publishes');
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
