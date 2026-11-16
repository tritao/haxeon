package driver;

import sys.FileSystem;

private typedef DriverOptions = {
	var root:String;
	var suites:Array<String>;
	var filter:Null<EReg>;
	var listOnly:Bool;
	var jobs:Int;

	/** `--check-reuse`: every program is also rebuilt warm, and every compile checks what it reuses (`CompileOptions.checkReuse`). */
	var checkReuse:Bool;
}

class TestDriver {
	static function main():Void {
		var previous = Sys.getEnv("TMPDIR"),
			temporary = createTemporaryDirectory();
		Sys.putEnv("TMPDIR", temporary);
		var status:Int;
		try
			status = run()
		catch (error:Dynamic) {
			removeTemporaryDirectory(temporary);
			Sys.putEnv("TMPDIR", previous);
			throw error;
		}
		removeTemporaryDirectory(temporary);
		Sys.putEnv("TMPDIR", previous);
		if (status != 0)
			Sys.exit(status);
	}

	static function run():Int {
		var options = parseOptions(Sys.args());
		var runner = new TestRunner(options.root);
		runner.checkReuse = options.checkReuse;
		var failures = 0;
		var selected = 0;
		var phaseStarted = Sys.time();

		var namedCases = TestCatalog.namedCases();
		for (entry in namedCases) {
			if (!matches(options, entry.suite, entry.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${entry.suite}\t${entry.name}');
		}
		if (!options.listOnly) {
			failures += runner.runHaxeMains(namedCases.filter(entry -> matches(options, entry.suite, entry.name)),
				options.jobs);
			printTiming("named cases", phaseStarted);
		}

		phaseStarted = Sys.time();
		var executableCases = TestCatalog.executableCases();
		for (test in executableCases) {
			if (!matches(options, test.suite, test.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${test.suite}\t${test.name}');
		}
		if (!options.listOnly) {
			var selectedExecutableCases = executableCases.filter(test -> matches(options, test.suite, test.name));
			failures += runner.runExecutables(selectedExecutableCases, options.jobs);
			printTiming("executable cases", phaseStarted);
		}

		phaseStarted = Sys.time();
		var programs = [];
		for (test in TestCatalog.loadPrograms(options.root)) {
			if (!matches(options, "programs", test.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('programs\t${test.name}');
			else
				programs.push(test);
		}
		if (!options.listOnly) {
			failures += runner.runPrograms(programs, options.jobs);
			printTiming("program cases", phaseStarted);
		}

		phaseStarted = Sys.time();
		for (test in TestCatalog.customCases()) {
			if (!matches(options, test.suite, test.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${test.suite}\t${test.name}');
			else if (!runner.runPosInfos())
				failures++;
		}
		if (!options.listOnly)
			printTiming("custom cases", phaseStarted);

		if (selected == 0)
			throw "No tests matched the requested suite and filter";
		if (options.listOnly)
			return 0;
		Sys.println('Test driver: ${selected - failures} passed, $failures failed, $selected total');
		return failures == 0 ? 0 : 1;
	}

	/** Every driver run owns its scratch directory, including direct Windows invocations. */
	static function createTemporaryDirectory():String {
		var parent = Sys.getEnv("TMPDIR");
		if (parent == null || parent == "")
			parent = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		if (parent == null || parent == "" || !FileSystem.exists(parent) || !FileSystem.isDirectory(parent))
			throw "No system temporary directory was found";
		for (_ in 0...100) {
			var path = haxe.io.Path.join([parent, 'haxeon-test-${Std.random(1000000000)}-${Std.random(1000000000)}']);
			// mkdir must claim the name atomically; another driver may choose the same name.
			var status = Sys.systemName() == "Windows" ? Sys.command("cmd",
				["/c", "mkdir", path]) : Sys.command("mkdir", [path]);
			if (status == 0)
				return path;
		}
		throw "Cannot create a unique test temporary directory";
	}

	static function removeTemporaryDirectory(path:String):Void {
		// Native recursive deletion removes links themselves, never their targets.
		var status = Sys.systemName() == "Windows" ? Sys.command("cmd",
			["/c", "rmdir", "/s", "/q", path]) : Sys.command("rm", [
				"-rf",
				"--",
				path
			]);
		if (status != 0)
			throw 'Cannot remove test temporary directory "$path"';
	}

	static function printTiming(phase:String, started:Float):Void {
		Sys.println('TIMING: test-driver $phase: ${Std.int((Sys.time() - started) * 1000)}ms');
	}

	static function matches(options:DriverOptions, suite:String, name:String):Bool {
		if (options.suites.indexOf("all") == -1 && options.suites.indexOf(suite) == -1)
			return false;
		return options.filter == null || options.filter.match(name);
	}

	static function parseOptions(args:Array<String>):DriverOptions {
		var root = Sys.getCwd();
		var suites = ["all"];
		var filter:Null<EReg> = null;
		var listOnly = false;
		var checkReuse = false;
		var jobs = 1;
		var index = 0;
		while (index < args.length) {
			switch args[index++] {
				case "--root":
					if (index == args.length)
						throw "--root requires a path";
					root = args[index++];
				case "--suite":
					if (index == args.length)
						throw "--suite requires a name";
					suites = args[index++].split(",");
				case "--test":
					if (index == args.length)
						throw "--test requires a regular expression";
					filter = new EReg(args[index++], "i");
				case "--list":
					listOnly = true;
				case "--check-reuse":
					checkReuse = true;
				case "--jobs":
					if (index == args.length)
						throw "--jobs requires a positive integer";
					var parsed:Null<Int> = Std.parseInt(args[index++]);
					if (parsed == null || parsed < 1)
						throw "--jobs requires a positive integer";
					jobs = parsed;
				case argument:
					throw 'Unknown test driver argument: $argument';
			}
		}
		return {
			root: FileSystem.fullPath(root),
			suites: suites,
			filter: filter,
			listOnly: listOnly,
			jobs: jobs,
			checkReuse: checkReuse
		};
	}
}
