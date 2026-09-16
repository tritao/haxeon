package runtime;

/**
	External owner for one published HashLink patch allocation.

	The native handle keeps executable memory and its patch metadata alive after
	HashLink has removed the allocation from the module's dispatch table.
 */
typedef RuntimeJitCodeHandle = hl.Abstract<"realtime_jit_code">;
