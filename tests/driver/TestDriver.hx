package driver;

import sys.FileSystem;

private typedef DriverOptions = {
	var root:String;
	var suites:Array<String>;
	var filter:Null<EReg>;
	var listOnly:Bool;
	var jobs:Int;
}

class TestDriver {
	static function main():Void {
		var options = parseOptions(Sys.args());
		var runner = new TestRunner(options.root);
		var failures = 0;
		var selected = 0;

		for (entry in TestCatalog.namedCases()) {
			if (!matches(options, entry.suite, entry.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${entry.suite}\t${entry.name}');
			else if (!runner.runHaxeMain(entry.name))
				failures++;
		}

		for (test in TestCatalog.executableCases()) {
			if (!matches(options, test.suite, test.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${test.suite}\t${test.name}');
			else if (!runner.runExecutable(test))
				failures++;
		}

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
		if (!options.listOnly)
			failures += runner.runPrograms(programs, options.jobs);

		for (test in TestCatalog.customCases()) {
			if (!matches(options, test.suite, test.name))
				continue;
			selected++;
			if (options.listOnly)
				Sys.println('${test.suite}\t${test.name}');
			else if (!runner.runPosInfos())
				failures++;
		}

		if (selected == 0)
			throw "No tests matched the requested suite and filter";
		if (options.listOnly)
			return;
		Sys.println('Test driver: ${selected - failures} passed, $failures failed, $selected total');
		if (failures != 0)
			Sys.exit(1);
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
				case "--jobs":
					if (index == args.length)
						throw "--jobs requires a positive integer";
					jobs = Std.parseInt(args[index++]);
					if (jobs == null || jobs < 1)
						throw "--jobs requires a positive integer";
				case argument:
					throw 'Unknown test driver argument: $argument';
			}
		}
		return {
			root: FileSystem.fullPath(root),
			suites: suites,
			filter: filter,
			listOnly: listOnly,
			jobs: jobs
		};
	}
}
