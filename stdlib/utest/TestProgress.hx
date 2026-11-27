package utest;

/** Result emitted after one selected test has finished. */
class TestProgress {
	/** The test's name. */
	public final name:String;

	/** Whether it passed. */
	public final success:Bool;

	/** How many of the selected tests have finished, this one included. */
	public final done:Int;

	/** How many tests are selected. */
	public final totals:Int;

	/** The result of the test `name`, the `done`th of `totals`. */
	public function new(name:String, success:Bool, done:Int, totals:Int) {
		this.name = name;
		this.success = success;
		this.done = done;
		this.totals = totals;
	}
}
