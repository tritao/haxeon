package utest;

/** Synchronous Haxeon implementation of the core utest runner API. */
class Runner {
	final cases:Array<Test> = [];

	public var successes(default, null):Int = 0;
	public var failures(default, null):Int = 0;
	public var setupFailures(default, null):Int = 0;
	public var teardownFailures(default, null):Int = 0;
	public var displayResults:Bool = false;

	public function new() {}

	public function addCase(testCase:Test):Void {
		testCase.registerTests();
		cases.push(testCase);
	}

	public function run():Void {
		for (testCase in cases) {
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
				var test = testCase.testFunctions[index];
				var testReady = true;
				try {
					testCase.setup();
				} catch (error:Dynamic) {
					testReady = false;
					recordSetupFailure(name + ".setup", error);
				}
				if (testReady) {
					try {
						test();
						successes++;
						if (displayResults)
							Sys.println("PASS: " + name);
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
				index++;
			}
			try {
				testCase.teardownClass();
			} catch (error:Dynamic) {
				recordTeardownFailure("teardownClass", error);
			}
		}
		if (displayResults)
			Sys.println("Tests: " + (successes + failures) + ", passed: " + successes + ", failed: " + failures);
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
