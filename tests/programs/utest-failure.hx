import utest.Assert;
import utest.Runner;
import utest.Test;

function doesNotRaise():Void {}

class FailureTest extends Test {
	public var tornDown:Bool = false;

	public function new() {
		super();
	}

	public function testFailure():Void {
		Assert.equals(42, 41, "answer mismatch");
	}

	public function testFloatFailure():Void {
		Assert.floatEquals(1.0, 2.0, 0.00001, "float mismatch");
	}

	public function testContainsFailure():Void {
		Assert.contains(4, [1, 2, 3], "missing value");
	}

	public function testNotContainsFailure():Void {
		Assert.notContains(2, [1, 2, 3], "unexpected value");
	}

	public function testRaisesFailure():Void {
		Assert.raises(doesNotRaise, "missing exception");
	}

	public function teardown():Void {
		tornDown = true;
	}

	public function registerTests():Void {
		addTest("FailureTest.testFailure", this.testFailure);
		addTest("FailureTest.testFloatFailure", this.testFloatFailure);
		addTest("FailureTest.testContainsFailure", this.testContainsFailure);
		addTest("FailureTest.testNotContainsFailure", this.testNotContainsFailure);
		addTest("FailureTest.testRaisesFailure", this.testRaisesFailure);
	}
}

function main():Int {
	var runner = new Runner();
	var test = new FailureTest();
	runner.addCase(test);
	runner.run();
	return runner.failures == 5 && test.tornDown ? 5 : 10;
}
