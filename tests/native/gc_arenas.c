#include <hl.h>
#include <stdio.h>
#include <stdlib.h>

/* While an arena is current on a thread, what the thread allocates without an owner of its own goes to the
   arena's pages. Releasing the arena reports how many of its blocks are still live and returns its pages once none is. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#else
#	define NOINLINE __attribute__((noinline))
#endif

#define COUNT 200000
static void *blocks[COUNT];
static void *kept[4];
static int arena_a, arena_b, arena_c;

static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}

static NOINLINE void scrub_stack(void) {
	volatile char junk[16384];
	for(int i=0;i<(int)sizeof(junk);i++) junk[i] = 0;
}

static unsigned long long heap_bytes(void) {
	unsigned long long a,b,c,d,e;
	hl_gc_profile_stats(&a,&b,&c,&d,&e);
	return c;
}

static NOINLINE void fill(int count) {
	for(int i=0;i<count;i++) blocks[i] = hl_gc_alloc_noptr(16 + (i & 3) * 16);
}

static NOINLINE void drop(int count) {
	for(int i=0;i<count;i++) blocks[i] = NULL;
}

static NOINLINE int released(void *arena) {
	scrub_stack();
	return hl_gc_arena_release(arena);
}

int main(void) {
	int marker = 0, result = 1;
	hl_global_init();
	hl_register_thread(&marker);
	hl_add_root(&blocks);
	for(int i=0;i<4;i++) hl_add_root(&kept[i]);
	(void)blocks;

	/* Everything allocated in an arena is dead at release: the count is zero and the pages go back. */
	for(int cycle=0;cycle<40;cycle++) {
		unsigned long long base, peak, after;
		hl_gc_major();
		base = heap_bytes();
		void *previous = hl_gc_arena_enter(&arena_a);
		if(!check(previous == NULL,"no arena is current at first")) goto done;
		fill(COUNT);
		hl_gc_arena_leave(previous);
		peak = heap_bytes();
		if(!check(peak > base + COUNT * 16 / 2,"the arena's blocks occupy pages")) goto done;
		drop(COUNT);
		if(!check(released(&arena_a) == 0,"an arena whose blocks all died counts none")) goto done;
		after = heap_bytes();
		if(!check(after < base + (1 << 20),"releasing it returns its pages")) goto done;
	}

	/* Blocks still reachable at release are counted and stay intact, the pages without one go back, and the rest are freed
	   once the blocks are unreachable. */
	{
		hl_gc_major();
		unsigned long long base = heap_bytes();
		void *previous = hl_gc_arena_enter(&arena_b);
		fill(COUNT);
		for(int i=0;i<4;i++) {
			kept[i] = hl_gc_alloc_noptr(32);
			for(int b=0;b<32;b++) ((unsigned char*)kept[i])[b] = 0x5a;
		}
		hl_gc_arena_leave(previous);
		drop(COUNT);
		if(!check(released(&arena_b) == 4,"a release counts the blocks that escaped the arena")) goto done;
		if(!check(heap_bytes() < base + (1 << 20),"and returns every page that holds none of them")) goto done;
		hl_gc_major();
		int intact = 1;
		for(int i=0;i<4;i++)
			for(int b=0;b<32;b++)
				if( ((unsigned char*)kept[i])[b] != 0x5a ) intact = 0;
		if(!check(intact,"escaped blocks stay valid")) goto done;
		for(int i=0;i<4;i++) kept[i] = NULL;
		hl_gc_major();
	}

	/* Arenas nest, and leaving one makes the enclosing one current again; outside any arena nothing goes to one. */
	{
		void *outer = hl_gc_arena_enter(&arena_a);
		kept[0] = hl_gc_alloc_noptr(16);
		void *inner = hl_gc_arena_enter(&arena_c);
		if(!check(inner == &arena_a,"entering returns the enclosing arena")) goto done;
		kept[1] = hl_gc_alloc_noptr(16);
		hl_gc_arena_leave(inner);
		kept[2] = hl_gc_alloc_noptr(16);
		hl_gc_arena_leave(outer);
		kept[3] = hl_gc_alloc_noptr(16);
		if(!check(released(&arena_c) == 1,"the inner arena holds only what was allocated inside it")) goto done;
		if(!check(released(&arena_a) == 2,"the outer arena holds what was allocated around the inner one")) goto done;
		for(int i=0;i<4;i++) kept[i] = NULL;
	}
	if(!check(hl_gc_arena_release(NULL) == 0,"releasing no arena does nothing")) goto done;
	result = 0;
done:
	return result;
}
