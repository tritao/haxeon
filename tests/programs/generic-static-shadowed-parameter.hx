// A static method's type parameter named as its generic class's own is the method's, not the class's: a function over it
// passed to the erased class's constructor crosses into the class's erased function type in every specialization.
class Task<T> {
	final run:Void->T;

	function new(run:Void->T)
		this.run = run;

	public static function start<T>(run:Void->T):Task<T>
		return new Task<T>(run);

	public function finish():T
		return run();
}

function main():Int {
	var count = 0;
	Task.start(() -> count += 2).finish();
	Task.start(() -> {
		count++;
	}).finish();
	return Task.start(() -> 39 + count).finish();
}
