import runtime.memory.Arena;
import runtime.memory.AtomicPointer;
import runtime.memory.MemoryOrder;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new Arena(),
		slot:RawPtr<RawPtr<UInt8>> = arena.alloc(),
		first:RawPtr<UInt8> = arena.alloc(),
		second:RawPtr<UInt8> = arena.alloc(),
		third:RawPtr<UInt8> = arena.alloc(),
		atomic = new AtomicPointer<UInt8>(slot);
	slot.store(first);
	var initial = atomic.load(MemoryOrder.Acquire),
		exchanged = atomic.exchange(second, MemoryOrder.AcqRel),
		failedObserved = atomic.compareExchangeObserved(first, third, MemoryOrder.AcqRel),
		afterFailure = atomic.load(MemoryOrder.Relaxed),
		succeeded = atomic.compareExchange(second, third, MemoryOrder.SeqCst),
		afterSuccess = atomic.load();
	atomic.store(first, MemoryOrder.Release);
	var correct = initial == first && exchanged == first && failedObserved == second && afterFailure == second && succeeded && afterSuccess == third
		&& atomic.load() == first;
	arena.dispose();
	return correct ? 42 : 1;
}
