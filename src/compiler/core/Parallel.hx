package compiler.core;

import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Runs independent pieces of work on several threads, the caller's among them. A piece is an index: `work(index)` must write
 * only what belongs to its index, such as a slot of an array the caller sized, and read nothing another piece writes. The caller
 * then sees the same results whatever the scheduling. The first exception a piece throws stops the pieces not yet started and is
 * rethrown to the caller once every thread is done. `threadEnd` runs on each thread started here before it ends, to let go of what
 * the work kept in thread-local storage, which the runtime keeps alive until it is cleared.
 */
class Parallel {
	public static function forEach(count:Int, threads:Int, work:Int->Void, ?threadEnd:() -> Void):Void {
		if (count <= 0)
			return;
		if (threads > count)
			threads = count;
		if (threads <= 1) {
			for (index in 0...count)
				work(index);
			return;
		}
		var next = 0, failure:Null<haxe.Exception> = null, mutex = new Mutex(), finished = new Lock();
		function take():Int {
			mutex.acquire();
			var index = failure == null && next < count ? next++ : -1;
			mutex.release();
			return index;
		}
		function run():Void {
			var index = take();
			while (index >= 0) {
				try
					work(index)
				catch (error:haxe.Exception) {
					mutex.acquire();
					if (failure == null)
						failure = error;
					mutex.release();
				}
				index = take();
			}
		}
		for (_ in 1...threads)
			Thread.create(function() {
				run();
				if (threadEnd != null)
					threadEnd();
				finished.release();
			});
		run();
		for (_ in 1...threads)
			finished.wait();
		var thrown = failure;
		if (thrown != null)
			throw thrown;
	}
}
