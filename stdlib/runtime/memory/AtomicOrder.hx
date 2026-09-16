package runtime.memory;

/** Shared validation and ABI encoding for runtime atomic operations. */
class AtomicOrder {
	public static inline function encode(order:MemoryOrder):Int
		return switch order {
			case Relaxed: 0;
			case Acquire: 1;
			case Release: 2;
			case AcqRel: 3;
			case SeqCst: 4;
		};

	public static inline function encodeLoad(order:MemoryOrder):Int
		return switch order {
			case Release | AcqRel:
				throw "Atomic loads cannot use release ordering";
			case _:
				encode(order);
		};

	public static inline function encodeStore(order:MemoryOrder):Int
		return switch order {
			case Acquire | AcqRel:
				throw "Atomic stores cannot use acquire ordering";
			case _:
				encode(order);
		};
}
