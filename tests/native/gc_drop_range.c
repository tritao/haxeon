/* Negative control: omit only the selected managed destination's barrier. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
static uintptr_t drop_begin, drop_end;
void gc_test_drop_range(void *address, size_t bytes) {
 drop_begin=(uintptr_t)address; drop_end=drop_begin+bytes;
}
void hl_gc_write_barrier(void *address, size_t bytes) {
 static void (*real_barrier)(void*,size_t);
 if(!real_barrier) real_barrier=dlsym(RTLD_NEXT,"hl_gc_write_barrier");
 if(drop_begin && (uintptr_t)address >= drop_begin && (uintptr_t)address < drop_end) return;
 real_barrier(address,bytes);
}
