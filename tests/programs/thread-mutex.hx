import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

// A mutex excludes: threads counting under it lose no update, and a free one can be taken at once.
function main():Int {
	var mutex = new Mutex();
	if (!mutex.tryAcquire())
		return 1;
	mutex.release();
	var total = [0], done = new Lock();
	for (_ in 0...4)
		Thread.create(function() {
			for (_ in 0...20000) {
				mutex.acquire();
				total[0] = total[0] + 1;
				mutex.release();
			}
			done.release();
		});
	for (_ in 0...4)
		done.wait();
	return total[0] == 80000 ? 42 : 2;
}
