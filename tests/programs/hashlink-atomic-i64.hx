import runtime.memory.Arena;
import runtime.memory.AtomicInt64;
import runtime.memory.MemoryOrder;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new Arena(),
		storage:RawPtr<Int64> = arena.alloc(),
		atomic = new AtomicInt64(storage);
	storage.store(haxe.Int64.ofInt(7));
	var initial = atomic.load(MemoryOrder.Relaxed),
		added = atomic.fetchAdd(haxe.Int64.ofInt(5), MemoryOrder.AcqRel),
		afterAdd = atomic.load(MemoryOrder.Acquire),
		exchanged = atomic.exchange(haxe.Int64.ofInt(42), MemoryOrder.Release),
		failed = !atomic.compareExchange(haxe.Int64.ofInt(7), haxe.Int64.ofInt(99), MemoryOrder.AcqRel),
		afterFailure = atomic.load(MemoryOrder.Relaxed),
		succeeded = atomic.compareExchange(haxe.Int64.ofInt(42), haxe.Int64.ofInt(43), MemoryOrder.SeqCst),
		afterSuccess = atomic.load(),
		observed = atomic.compareExchangeObserved(haxe.Int64.ofInt(44), haxe.Int64.ofInt(45), MemoryOrder.Acquire);
	atomic.store(haxe.Int64.ofInt(43), MemoryOrder.Release);
	AtomicInt64.fence(MemoryOrder.Acquire);
	var correct = haxe.Int64.toInt(initial) == 7
		&& haxe.Int64.toInt(added) == 7
		&& haxe.Int64.toInt(afterAdd) == 12
		&& haxe.Int64.toInt(exchanged) == 12
		&& failed
		&& haxe.Int64.toInt(afterFailure) == 42
		&& succeeded
		&& haxe.Int64.toInt(afterSuccess) == 43
		&& haxe.Int64.toInt(observed) == 43
		&& haxe.Int64.toInt(atomic.load()) == 43;
	arena.dispose();
	return correct ? 42 : 1;
}
