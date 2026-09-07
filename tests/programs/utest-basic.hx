import utest.Assert;
import utest.Runner;
import utest.Test;
import utest.ui.Report;

class MathTest extends Test {
	public function new() {
		super();
	}

	public function testAddition():Void {
		Assert.equals(42, 20 + 22);
	}

	public function testPredicates():Void {
		Assert.isTrue(3 < 4);
		Assert.isFalse(false);
		Assert.notEquals(1, 2);
	}

	public function registerTests():Void {
		addTest("MathTest.testAddition", this.testAddition);
		addTest("MathTest.testPredicates", this.testPredicates);
	}
}

function main():Int {
	var runner = new Runner();
	runner.addCase(new MathTest());
	Report.create(runner);
	runner.run();
	return runner.failures == 0 ? 0 : 1;
}
