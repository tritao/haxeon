/* Negative controls for the software write barrier, linked into a test program that hosts the VM itself:
 *
 *   cc ... gc_drop_barriers.c -Wl,--wrap=hl_gc_write_barrier -rdynamic
 *
 * The VM is one executable, so a preloaded library cannot replace a function of it; --wrap sends every call to the barrier
 * here instead, and __real_hl_gc_write_barrier is the VM's own. Inactive unless asked: HL_GC_TEST_DROP_BARRIERS=1 drops every
 * barrier, and HL_GC_TEST_DROP_BARRIERS=range drops those for the one managed destination the program names with
 * gc_test_drop_range(address, bytes) (found with dlsym, hence -rdynamic). The survival tests must then fail. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void __real_hl_gc_write_barrier(void *address, size_t bytes);

static uintptr_t drop_begin, drop_end;

void gc_test_drop_range(void *address, size_t bytes) {
	drop_begin = (uintptr_t)address;
	drop_end = drop_begin + bytes;
}

enum { DROP_NONE, DROP_ALL, DROP_RANGE };

void __wrap_hl_gc_write_barrier(void *address, size_t bytes) {
	static int mode = -1;
	if( mode < 0 ) {
		const char *value = getenv("HL_GC_TEST_DROP_BARRIERS");
		mode = value == NULL ? DROP_NONE : strcmp(value,"1") == 0 ? DROP_ALL : strcmp(value,"range") == 0 ? DROP_RANGE : DROP_NONE;
	}
	if( mode == DROP_ALL ) return;
	if( mode == DROP_RANGE && drop_begin && (uintptr_t)address >= drop_begin && (uintptr_t)address < drop_end ) return;
	__real_hl_gc_write_barrier(address,bytes);
}
