package utest;

import utest.ProgressEvent;
import utest.RunnerEvent;
import utest.TestProgress;

/** Synchronous Haxeon implementation of the core utest runner API. */
class Runner {
	final cases:Array<Test> = [];
	final filters:Array<String> = [];

	public var successes(default, null):Int = 0;
	public var failures(default, null):Int = 0;
	public var setupFailures(default, null):Int = 0;
	public var teardownFailures(default, null):Int = 0;
	public var displayResults:Bool = false;
	public var globalPattern:String = "";
	public var length(default, null):Int = 0;
	public final onStart:RunnerEvent;
	public final onProgress:ProgressEvent;
	public final onComplete:RunnerEvent;

	public function new() {
		onStart = new RunnerEvent();
		onProgress = new ProgressEvent();
		onComplete = new RunnerEvent();
	}

	public function addCase(testCase:Test, filter:String = ""):Void {
		testCase.registerTests();
		cases.push(testCase);
		filters.push(filter);
	}

	public function run():Void {
		length = selectedCount();
		var done = 0;
		onStart.dispatch(this);
		var caseIndex = 0;
		while (caseIndex < cases.length) {
			var testCase = cases[caseIndex];
			var filter = filters[caseIndex] == "" ? globalPattern : filters[caseIndex];
			var classReady = true;
			try {
				testCase.setupClass();
			} catch (error:Dynamic) {
				classReady = false;
				recordSetupFailure("setupClass", error);
			}
			var index = 0;
			while (classReady && index < testCase.testFunctions.length) {
				var name = testCase.testNames[index];
				if (!matches(name, filter)) {
					index++;
					continue;
				}
				var test = testCase.testFunctions[index];
				var testReady = true;
				var failuresBefore = failures;
				try {
					testCase.setup();
				} catch (error:Dynamic) {
					testReady = false;
					recordSetupFailure(name + ".setup", error);
				}
				if (testReady) {
					try {
						test();
					} catch (error:Dynamic) {
						failures++;
						Sys.println("FAIL: " + name + ": " + Std.string(error));
					}
				}
				try {
					testCase.teardown();
				} catch (error:Dynamic) {
					recordTeardownFailure(name + ".teardown", error);
				}
				var success = failures == failuresBefore;
				if (success) {
					successes++;
					if (displayResults)
						Sys.println("PASS: " + name);
				}
				done++;
				onProgress.dispatch(new TestProgress(name, success, done, length));
				index++;
			}
			try {
				testCase.teardownClass();
			} catch (error:Dynamic) {
				recordTeardownFailure("teardownClass", error);
			}
			caseIndex++;
		}
		if (displayResults)
			Sys.println("Tests: " + (successes + failures) + ", passed: " + successes + ", failed: " + failures);
		onComplete.dispatch(this);
	}

	function selectedCount():Int {
		var total = 0;
		var caseIndex = 0;
		while (caseIndex < cases.length) {
			var filter = filters[caseIndex] == "" ? globalPattern : filters[caseIndex];
			for (name in cases[caseIndex].testNames)
				if (matches(name, filter))
					total++;
			caseIndex++;
		}
		return total;
	}

	function matches(name:String, filter:String):Bool {
		return filter == "" || name.indexOf(filter) >= 0;
	}

	function recordSetupFailure(name:String, error:Dynamic):Void {
		failures++;
		setupFailures++;
		Sys.println("SETUP FAIL: " + name + ": " + Std.string(error));
	}

	function recordTeardownFailure(name:String, error:Dynamic):Void {
		failures++;
		teardownFailures++;
		Sys.println("TEARDOWN FAIL: " + name + ": " + Std.string(error));
	}
}
