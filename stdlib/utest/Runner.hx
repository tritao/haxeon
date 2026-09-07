package utest;

/** Synchronous Haxeon implementation of the core utest runner API. */
class Runner {
	final cases:Array<Test> = [];

	public var successes(default, null):Int = 0;
	public var failures(default, null):Int = 0;
	public var displayResults:Bool = false;

	public function new() {}

	public function addCase(testCase:Test):Void {
		testCase.registerTests();
		cases.push(testCase);
	}

	public function run():Void {
		for (testCase in cases) {
			var index = 0;
			while (index < testCase.testFunctions.length) {
				var name = testCase.testNames[index];
				var test = testCase.testFunctions[index];
				try {
					test();
					successes++;
					if (displayResults)
						Sys.println("PASS: " + name);
				} catch (error:Dynamic) {
					failures++;
					Sys.println("FAIL: " + name + ": " + Std.string(error));
				}
				index++;
			}
		}
		if (displayResults)
			Sys.println("Tests: " + (successes + failures) + ", passed: " + successes + ", failed: " + failures);
	}
}
