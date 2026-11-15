// The calling thread's stack bounds, for tests of what touching the stack's guard does.
#define _GNU_SOURCE
#define HL_NAME(n) stack_probe_##n
#include <hl.h>
#include <pthread.h>
#include <stdint.h>

static uintptr_t usable_low;
static size_t guard_size;

// Records the lowest usable address of the calling thread's stack and the size of the guard below it.
HL_PRIM bool HL_NAME(measure)( void ) {
	pthread_attr_t attr;
	void *address;
	size_t size;
	if( pthread_getattr_np(pthread_self(), &attr) != 0 ) return false;
	bool ok = pthread_attr_getstack(&attr, &address, &size) == 0 && pthread_attr_getguardsize(&attr, &guard_size) == 0;
	pthread_attr_destroy(&attr);
	usable_low = (uintptr_t)address;
	return ok && guard_size > 0;
}

HL_PRIM int HL_NAME(low_high)( void ) { return (int)(uint32_t)((uint64_t)usable_low >> 32); }
HL_PRIM int HL_NAME(low_low)( void ) { return (int)(uint32_t)usable_low; }
HL_PRIM int HL_NAME(guard)( void ) { return (int)guard_size; }

DEFINE_PRIM(_BOOL, measure, _NO_ARG);
DEFINE_PRIM(_I32, low_high, _NO_ARG);
DEFINE_PRIM(_I32, low_low, _NO_ARG);
DEFINE_PRIM(_I32, guard, _NO_ARG);
