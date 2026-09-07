import utest.Assert;
import utest.Runner;
import utest.Test;
import utest.ui.Report;

function genericDefault<T>(value:T, enabled:Bool = true):T {
	return value;
}

function genericOptional<T>(value:T, ?message:String):T {
	return value;
}

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

	public function testNulls():Void {
		var missing:Null<String> = null;
		var present:Null<String> = "value";
		Assert.isNull(missing);
		Assert.notNull(present);
	}

	public function registerTests():Void {
		addTest("MathTest.testAddition", this.testAddition);
		addTest("MathTest.testPredicates", this.testPredicates);
		addTest("MathTest.testNulls", this.testNulls);
	}
}

function main():Int {
	if (genericDefault(42) != 42 || genericOptional(42) != 42)
		return 2;
	var runner = new Runner();
	runner.addCase(new MathTest());
	Report.create(runner);
	runner.run();
	return runner.failures == 0 ? 0 : 1;
}
