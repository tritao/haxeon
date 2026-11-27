package utest;

/** Base class for a Haxeon utest case. */
@:discoverMethods("test", "spec")
class Test {
	/** The names of the case's tests, in the order they run. */
	public final testNames:Array<String> = [];

	/** The case's tests, in the order of `testNames`. */
	public final testFunctions:Array<() -> Void> = [];

	/** A case. Its methods named `test...` or `spec...` are its tests, found by the compiler. */
	public function new() {}

	/** Runs once before this case's registered tests. */
	public function setupClass():Void {}

	/** Runs before each registered test. */
	public function setup():Void {}

	/** Runs after each registered test, including failed setup or test calls. */
	public function teardown():Void {}

	/** Runs once after this case, including when setupClass fails. */
	public function teardownClass():Void {}

	/** May be overridden when explicit registration is preferable. */
	public function registerTests():Void {}

	/** Adds the test `test` named `name`. */
	public function addTest(name:String, test:() -> Void):Void {
		testNames.push(name);
		testFunctions.push(test);
	}
}
