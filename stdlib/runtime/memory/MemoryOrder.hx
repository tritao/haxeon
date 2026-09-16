package runtime.memory;

/** C11-compatible ordering modes for runtime atomic operations. */
enum MemoryOrder {
	Relaxed;
	Acquire;
	Release;
	AcqRel;
	SeqCst;
}
