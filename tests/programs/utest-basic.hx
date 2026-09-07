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

class LifecycleTest extends Test {
	public final events:Array<Int> = [];

	public function new() {
		super();
	}

	public function setupClass():Void {
		events.push(1);
	}

	public function setup():Void {
		events.push(2);
	}

	public function testFirst():Void {
		events.push(3);
	}

	public function testSecond():Void {
		events.push(4);
	}

	public function teardown():Void {
		events.push(5);
	}

	public function teardownClass():Void {
		events.push(6);
	}

	public function registerTests():Void {
		addTest("LifecycleTest.testFirst", this.testFirst);
		addTest("LifecycleTest.testSecond", this.testSecond);
	}
}

function main():Int {
	if (genericDefault(42) != 42 || genericOptional(42) != 42)
		return 2;
	var runner = new Runner();
	var lifecycle = new LifecycleTest();
	runner.addCase(new MathTest());
	runner.addCase(lifecycle);
	Report.create(runner);
	runner.run();
	if (lifecycle.events.length != 8 || lifecycle.events[0] != 1 || lifecycle.events[1] != 2 || lifecycle.events[2] != 3 || lifecycle.events[3] != 5
		|| lifecycle.events[4] != 2 || lifecycle.events[5] != 4 || lifecycle.events[6] != 5 || lifecycle.events[7] != 6)
		return 3;
	return runner.failures == 0 ? 0 : 1;
}
