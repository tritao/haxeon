import runtime.memory.Arena;
import runtime.memory.AtomicInt32;
import runtime.memory.MemoryOrder;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new Arena(),
		storage:RawPtr<Int32> = arena.alloc(),
		atomic = new AtomicInt32(storage);
	storage.store(7);
	var initial = atomic.load(MemoryOrder.Relaxed),
		added = atomic.fetchAdd(5, MemoryOrder.AcqRel),
		afterAdd = atomic.load(MemoryOrder.Acquire),
		exchanged = atomic.exchange(42, MemoryOrder.Release),
		failed = !atomic.compareExchange(7, 99, MemoryOrder.AcqRel),
		afterFailure = atomic.load(MemoryOrder.Relaxed),
		succeeded = atomic.compareExchange(42, 43, MemoryOrder.SeqCst),
		afterSuccess = atomic.load(),
		invalidLoadRejected = false,
		invalidStoreRejected = false;
	try
		atomic.load(MemoryOrder.Release);
	catch (_:Dynamic)
		invalidLoadRejected = true;
	try
		atomic.store(44, MemoryOrder.AcqRel);
	catch (_:Dynamic)
		invalidStoreRejected = true;
	atomic.store(43, MemoryOrder.Release);
	AtomicInt32.fence(MemoryOrder.Acquire);
	var correct = initial == 7 && added == 7 && afterAdd == 12 && exchanged == 12 && failed && afterFailure == 42 && succeeded && afterSuccess == 43;
	correct = correct && invalidLoadRejected && invalidStoreRejected && atomic.load() == 43;
	arena.dispose();
	return correct ? 42 : 1;
}
