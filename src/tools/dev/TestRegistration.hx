package tools.dev;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon dev check-tests`: fails when a runnable test file under tests/ is run by nothing, so a new test cannot be added and silently
 * never run. The `test-registration` suite of tests/suites.txt runs it; tests/driver/TestCatalog.hx checks tests/programs the same way.
 *
 * The test files are the scripts (`.sh`, `.py`, `.ps1`), the `.hxml` entry files and the `*Main.hx` mains directly in a directory of
 * tests/ (tests/bench holds benchmarks, one level deeper, and is not checked), and tests/TestMain.hx. A file is run when what runs the
 * tests names it: a suite command of tests/suites.txt, the test driver (tests/driver, which the driver-default suite runs), a GitHub
 * workflow, or a file one of those reaches in turn (a test script, a helper script under scripts/, an hxml file, a test main, a source
 * file beside the mains). A file names another by its file name (`test-hot-reload.sh`, `plugin-test.hxml`) or, for Haxe, by its class
 * name (`ModuleMain`), as a whole word.
 *
 * tests/unregistered.txt lists the files that are deliberately not run, each with its reason: helpers, manual tools, and tests that
 * fail today or need what CI does not have. A listed file that something runs, or that does not exist, is an error too, so the list
 * cannot go stale.
 */
class TestRegistration {
	static final SCRIPT_EXTENSIONS = ["sh", "py", "ps1", "hxml"];

	public static function run(arguments:Array<String>, home:String):Int {
		if (arguments.length != 0) {
			Sys.stderr().writeString("Usage: haxeon dev check-tests\n");
			return 2;
		}
		var tests = testFiles(home), excluded = readExclusions(home), problems = [];
		var reached = reach(home, roots(home), carriers(home, tests), excluded);
		for (path in tests)
			if (!reached.exists(path) && !excluded.exists(path))
				problems.push('$path is run by no suite, test driver case or workflow: register it, or list it with its reason in '
					+ 'tests/unregistered.txt');
		var isTest = [for (path in tests) path => true];
		for (path => _ in excluded) {
			if (!isTest.exists(path))
				problems.push('tests/unregistered.txt lists $path, which is not a test file (or does not exist)');
			else if (reached.exists(path))
				problems.push('tests/unregistered.txt lists $path, but ${reached.get(path)} runs it: remove it from the list');
		}
		problems.sort(Reflect.compare);
		for (problem in problems)
			Sys.stderr().writeString('FAIL: $problem\n');
		if (problems.length > 0)
			return 1;
		var count = 0;
		for (_ in excluded)
			count++;
		Sys.println('PASS: ${tests.length - count} test files under tests/ are run by a suite, the test driver or a workflow; $count more '
			+ 'are listed in tests/unregistered.txt');
		return 0;
	}

	/** The runnable test files, relative to the checkout. */
	static function testFiles(home:String):Array<String> {
		var result = [];
		for (directory in [""].concat(directories(home, "tests")))
			for (name in FileSystem.readDirectory(Path.join([home, "tests", directory]))) {
				var relative = directory == "" ? 'tests/$name' : 'tests/$directory/$name';
				if (FileSystem.isDirectory(Path.join([home, relative])))
					continue;
				var extension = Path.extension(name);
				if (directory == "" ? name == "TestMain.hx" : (SCRIPT_EXTENSIONS.indexOf(extension) >= 0
					|| StringTools.endsWith(name, "Main.hx")))
					result.push(relative);
			}
		result.sort(Reflect.compare);
		return result;
	}

	/** What runs the tests: the suite commands, the test driver and the workflows. */
	static function roots(home:String):Array<{path:String, text:String}> {
		var suites = Path.join([home, "tests", "suites.txt"]);
		var result = [
			{
				path: "tests/suites.txt",
				text: [for (suite in SuiteManifest.parse(suites)) suite.command].join("\n")
			}
		];
		for (path in files(home, "tests/driver").concat(files(home, ".github/workflows")))
			result.push({path: path, text: File.getContent(Path.join([home, path]))});
		return result;
	}

	/**
	 * The files that carry a reference on when something reaches them: the test files, the other files beside them (sources a main
	 * calls, helper scripts) and the scripts under scripts/ and packages' tools/. Program, fixture and benchmark sources run no tests.
	 */
	static function carriers(home:String, tests:Array<String>):Array<String> {
		var result = tests.copy(), seen = [for (path in tests) path => true];
		for (directory in directories(home, "tests"))
			if (["driver", "programs", "fixtures", "bench"].indexOf(directory) < 0)
				for (path in files(home, 'tests/$directory'))
					if (!seen.exists(path))
						result.push(path);
		var pending = ["scripts"].concat([for (name in directories(home, "packages")) 'packages/$name/tools']);
		while (pending.length > 0) {
			var directory = pending.pop();
			if (!FileSystem.exists(Path.join([home, directory])))
				continue;
			result = result.concat(files(home, directory));
			for (name in directories(home, directory))
				pending.push('$directory/$name');
		}
		return result;
	}

	/**
	 * Every carrier the roots reach, transitively, with the file that first named it. An excluded file can be reached (and is then
	 * reported as stale), but what it names is not run on its account.
	 */
	static function reach(home:String, roots:Array<{path:String, text:String}>, carriers:Array<String>,
			excluded:Map<String, String>):Map<String, String> {
		var byName = new Map<String, Array<String>>();
		for (path in carriers) {
			var name = Path.withoutDirectory(path);
			if (Path.extension(name) == "hx")
				name = Path.withoutExtension(name);
			if (!byName.exists(name))
				byName.set(name, []);
			byName.get(name).push(path);
		}
		var reached = new Map<String, String>(), queue = roots.copy();
		while (queue.length > 0) {
			var source = queue.shift();
			for (word in words(source.text))
				for (path in byName.get(word) ?? [])
					if (path != source.path && !reached.exists(path)) {
						reached.set(path, source.path);
						if (!excluded.exists(path))
							queue.push({path: path, text: content(home, path)});
					}
		}
		return reached;
	}

	/** The words of a text a file can be named by: `a/b/test-x.sh.` gives `test-x.sh`, `test-x` and `sh`; `ModuleMain.run` gives both. */
	static function words(text:String):Array<String> {
		var result = [], pattern = ~/[A-Za-z0-9_.-]+/, position = 0;
		while (pattern.matchSub(text, position)) {
			var word = pattern.matched(0), matched = pattern.matchedPos();
			position = matched.pos + matched.len;
			while (StringTools.endsWith(word, "."))
				word = word.substr(0, word.length - 1);
			result.push(word);
			if (word.indexOf(".") >= 0)
				for (part in word.split("."))
					result.push(part);
		}
		return result;
	}

	/** A binary or unreadable file names nothing. */
	static function content(home:String, path:String):String {
		try {
			var bytes = File.getBytes(Path.join([home, path]));
			for (index in 0...bytes.length)
				if (bytes.get(index) == 0)
					return "";
			return bytes.toString();
		} catch (_:Dynamic) {
			return "";
		}
	}

	/**
	 * tests/unregistered.txt: `<path> <reason>` lines, `#` comments; the reason is required. Groups (helpers, manual tools, tests not
	 * run) are comment headers.
	 */
	static function readExclusions(home:String):Map<String, String> {
		var result = new Map<String, String>(), number = 0;
		for (raw in File.getContent(Path.join([home, "tests", "unregistered.txt"])).split("\n")) {
			number++;
			var line = StringTools.trim(raw);
			if (line == "" || StringTools.startsWith(line, "#"))
				continue;
			var space = ~/\s/;
			if (!space.match(line) || StringTools.trim(space.matchedRight()) == "")
				throw 'tests/unregistered.txt:$number: expected <path> <reason>';
			var path = space.matchedLeft();
			if (result.exists(path))
				throw 'tests/unregistered.txt:$number: $path is listed twice';
			result.set(path, StringTools.trim(space.matchedRight()));
		}
		return result;
	}

	static function directories(home:String, directory:String):Array<String> {
		var absolute = Path.join([home, directory]);
		if (!FileSystem.exists(absolute))
			return [];
		var result = [
			for (name in FileSystem.readDirectory(absolute))
				if (FileSystem.isDirectory(Path.join([absolute, name])) && name != "__pycache__") name
		];
		result.sort(Reflect.compare);
		return result;
	}

	static function files(home:String, directory:String):Array<String> {
		var absolute = Path.join([home, directory]);
		if (!FileSystem.exists(absolute))
			return [];
		var result = [
			for (name in FileSystem.readDirectory(absolute))
				if (!FileSystem.isDirectory(Path.join([absolute, name]))) '$directory/$name'
		];
		result.sort(Reflect.compare);
		return result;
	}
}
