import utest.Assert;
import utest.Runner;
import utest.Test;

class FailureTest extends Test {
	public function new() {
		super();
	}

	public function testFailure():Void {
		Assert.equals(42, 41, "answer mismatch");
	}

	public function registerTests():Void {
		addTest("FailureTest.testFailure", this.testFailure);
	}
}

function main():Int {
	var runner = new Runner();
	runner.addCase(new FailureTest());
	runner.run();
	return runner.failures == 1 ? 1 : 2;
}
