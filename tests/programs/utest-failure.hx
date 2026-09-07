import utest.Assert;
import utest.Runner;
import utest.Test;

class FailureTest extends Test {
	public var tornDown:Bool = false;

	public function new() {
		super();
	}

	public function testFailure():Void {
		Assert.equals(42, 41, "answer mismatch");
	}

	public function teardown():Void {
		tornDown = true;
	}

	public function registerTests():Void {
		addTest("FailureTest.testFailure", this.testFailure);
	}
}

function main():Int {
	var runner = new Runner();
	var test = new FailureTest();
	runner.addCase(test);
	runner.run();
	return runner.failures == 1 && test.tornDown ? 1 : 2;
}
