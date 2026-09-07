import utest.Runner;
import utest.Test;

class HookFailureTest extends Test {
	public var testRan:Bool = false;
	public var teardownRan:Bool = false;

	public function new() {
		super();
	}

	public function setup():Void {
		throw "setup failure";
	}

	public function testSkipped():Void {
		testRan = true;
	}

	public function teardown():Void {
		teardownRan = true;
	}

	public function teardownClass():Void {
		throw "teardownClass failure";
	}
}

function main():Int {
	var runner = new Runner();
	var test = new HookFailureTest();
	runner.addCase(test);
	runner.run();
	if (test.testRan || !test.teardownRan)
		return 10;
	if (runner.setupFailures != 1 || runner.teardownFailures != 1)
		return 11;
	return runner.failures;
}
