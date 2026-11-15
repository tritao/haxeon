import sys.thread.Deque;
import sys.thread.Thread;

/**
 * Stress for GC threads that start and hand values over through deques while collections run: each worker captures its own
 * data and sums what it pops, so a lost closure or a corrupted queue shows up as a wrong total or a crash. It exercises the
 * paths of the thread-start and deque-pop fixes (upstream e51e7b1, 1c167ed) but does not reproduce their races on demand,
 * which need a collection at an exact point; it did not fail on the VM before those fixes. Compiled by Haxe, not by Haxeon.
 */
class GcThreadHandoffMain {
	static function churn(n:Int):Int {
		var keep = 0;
		for (i in 0...n) {
			var a = [for (j in 0...16) {v: j + i}];
			keep += a[i % 16].v;
		}
		return keep;
	}

	static function main():Void {
		var results = new Deque<Int>();
		var work = new Deque<Null<Array<Int>>>();
		var threads = 16, items = 400;
		for (t in 0...threads) {
			var captured = [for (k in 0...64) t * 1000 + k];
			Thread.create(() -> {
				churn(200);
				var sum = 0;
				while (true) {
					var item = work.pop(true);
					if (item == null)
						break;
					sum += item[0] + captured[0] - t * 1000;
					churn(5);
				}
				results.add(sum);
			});
			hl.Gc.major();
		}
		var expected = 0;
		for (i in 0...items) {
			work.add([i]);
			expected += i;
			if (i % 50 == 0)
				hl.Gc.major();
		}
		for (t in 0...threads)
			work.add(null);
		var total = 0;
		for (t in 0...threads)
			total += results.pop(true);
		if (total != expected) {
			Sys.println('FAIL: workers summed $total instead of $expected');
			Sys.exit(1);
		}
		Sys.println("PASS: GC threads start and hand values over through deques while collections run");
	}
}
