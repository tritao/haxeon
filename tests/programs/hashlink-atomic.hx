import runtime.memory.Arena;
import runtime.memory.AtomicInt32;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new Arena(),
		storage:RawPtr<Int32> = arena.alloc(),
		atomic = new AtomicInt32(storage);
	storage.store(7);
	var initial = atomic.load(),
		added = atomic.fetchAdd(5),
		afterAdd = atomic.load(),
		exchanged = atomic.exchange(42),
		failed = !atomic.compareExchange(7, 99),
		afterFailure = atomic.load(),
		succeeded = atomic.compareExchange(42, 43),
		afterSuccess = atomic.load();
	AtomicInt32.fence();
	var correct = initial == 7 && added == 7 && afterAdd == 12 && exchanged == 12 && failed && afterFailure == 42 && succeeded && afterSuccess == 43;
	arena.dispose();
	return correct ? 42 : 1;
}
