import utest.Assert;
import utest.Runner;
import utest.Test;
import utest.TestProgress;
import utest.ui.Report;

function genericDefault<T>(value:T, enabled:Bool = true):T {
	return value;
}

function genericOptional<T>(value:T, ?message:String):T {
	return value;
}

function raiseExpected():Void {
	throw "expected";
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

	public function testAdditionalAssertions():Void {
		Assert.floatEquals(1.0, 1.000001);
		Assert.floatEquals(0.0 / 0.0, 0.0 / 0.0);
		Assert.contains(2, [1, 2, 3]);
		Assert.notContains(4, [1, 2, 3]);
		Assert.raises(raiseExpected);
	}

	public function registerTests():Void {
		addTest("MathTest.testAddition", this.testAddition);
		addTest("MathTest.testPredicates", this.testPredicates);
		addTest("MathTest.testNulls", this.testNulls);
		addTest("MathTest.testAdditionalAssertions", this.testAdditionalAssertions);
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

class FilterTest extends Test {
	public var includedRan:Bool = false;
	public var excludedRan:Bool = false;

	public function new() {
		super();
	}

	public function testIncluded():Void {
		includedRan = true;
	}

	public function testExcluded():Void {
		excludedRan = true;
	}

	public function registerTests():Void {
		addTest("FilterTest.testIncluded", this.testIncluded);
		addTest("FilterTest.testExcluded", this.testExcluded);
	}
}

class RunObserver {
	public var started:Bool = false;
	public var completed:Bool = false;
	public var progressCount:Int = 0;
	public var lastTotal:Int = 0;

	public function new() {}

	public function start(runner:Runner):Void {
		started = true;
	}

	public function progress(value:TestProgress):Void {
		progressCount++;
		lastTotal = value.totals;
	}

	public function complete(runner:Runner):Void {
		completed = true;
	}
}

function main():Int {
	if (genericDefault(42) != 42 || genericOptional(42) != 42)
		return 2;
	var runner = new Runner();
	var lifecycle = new LifecycleTest();
	var filtered = new FilterTest();
	var observer = new RunObserver();
	runner.onStart.add(observer.start);
	runner.onProgress.add(observer.progress);
	runner.onComplete.add(observer.complete);
	runner.addCase(new MathTest());
	runner.addCase(lifecycle);
	runner.addCase(filtered, "Included");
	Report.create(runner);
	runner.run();
	if (lifecycle.events.length != 8 || lifecycle.events[0] != 1 || lifecycle.events[1] != 2 || lifecycle.events[2] != 3 || lifecycle.events[3] != 5
		|| lifecycle.events[4] != 2 || lifecycle.events[5] != 4 || lifecycle.events[6] != 5 || lifecycle.events[7] != 6)
		return 3;
	if (!observer.started || !observer.completed || observer.progressCount != 7 || observer.lastTotal != 7 || runner.length != 7)
		return 4;
	if (!filtered.includedRan || filtered.excludedRan)
		return 5;
	return runner.failures == 0 ? 0 : 1;
}
