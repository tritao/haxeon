package utest;

/** Result emitted after one selected test has finished. */
class TestProgress {
	public final name:String;
	public final success:Bool;
	public final done:Int;
	public final totals:Int;

	public function new(name:String, success:Bool, done:Int, totals:Int) {
		this.name = name;
		this.success = success;
		this.done = done;
		this.totals = totals;
	}
}
