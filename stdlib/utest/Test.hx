package utest;

/** Base class for a Haxeon utest case. */
class Test {
	public final testNames:Array<String> = [];
	public final testFunctions:Array<() -> Void> = [];

	public function new() {}

	/**
	 * Override this method and call addTest for each test method.
	 * Upstream utest performs this step with a build macro, which Haxeon does
	 * not support yet.
	 */
	public function registerTests():Void {}

	public function addTest(name:String, test:() -> Void):Void {
		testNames.push(name);
		testFunctions.push(test);
	}
}
