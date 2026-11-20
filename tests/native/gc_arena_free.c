#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* An arena released without a collection (hl_gc_arena_free): its pages are reused at once when nothing outside points into
   it, and handed to the collector when something does, whether the reference is in a page of the heap, a root or a
   stack slot. With HL_GC_ARENA_TRACKING=0 no release is checked and every arena goes to the collector. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);
HL_PRIM double hl_gc_allocated_since_collection(void);

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#else
#	define NOINLINE __attribute__((noinline))
#endif

#define COUNT 100000
static void **blocks;
static void *global_slot;
static varray *table;
static void **outside;
static int tracked;
static int arena_a, arena_b, arena_c, arena_d, arena_e, arena_f, arena_g;

static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}

static unsigned long long heap_bytes(void) {
	unsigned long long a,b,c,d,e;
	hl_gc_profile_stats(&a,&b,&c,&d,&e);
	return c;
}

static unsigned long long collections(void) {
	unsigned long long a,b,c,d,e;
	hl_gc_profile_stats(&a,&b,&c,&d,&e);
	return d;
}

static NOINLINE void scrub_stack(void) {
	volatile char junk[16384];
	for(int i=0;i<(int)sizeof(junk);i++) junk[i] = 0;
}

/* Fills an arena with linked blocks (each points to the one before), dropped before it returns: only `blocks` holds them,
   and it is cleared. Returns the last block when `keep`. */
static NOINLINE void *fill(void *arena, int count, int keep) {
	void *previous = hl_gc_arena_enter(arena);
	void *last = NULL;
	for(int i=0;i<count;i++) {
		void **block = (void**)hl_gc_alloc_raw(16 + (i & 7) * 8);
		block[0] = last;
		last = block;
		blocks[i % COUNT] = block;
	}
	hl_gc_arena_leave(previous);
	for(int i=0;i<COUNT;i++) blocks[i] = NULL;
	return keep ? last : NULL;
}

static NOINLINE int freed(void *arena) {
	scrub_stack();
	return hl_gc_arena_free(arena);
}

/* Keeps `value` in this frame's stack slot while the arena is released. */
static NOINLINE int freed_with_stack_slot(void *arena, void *value) {
	void * volatile slot = value;
	scrub_stack();
	int result = hl_gc_arena_free(arena);
	return slot == value ? result : -100;
}

static int expect_kept(int found, const char *label) {
	return check(tracked ? found > 0 : found == -1,label);
}

static int chain_intact(void **last, int count) {
	int n = 0;
	while( last ) { n++; last = (void**)last[0]; }
	return n == count;
}

int main(void) {
	int marker = 0, result = 1;
	hl_global_init();
	hl_register_thread(&marker);
	blocks = (void**)malloc(sizeof(void*) * COUNT);
	memset(blocks,0,sizeof(void*) * COUNT);
	hl_add_root(&global_slot);
	hl_add_root(&outside);
	hl_add_root(&table);
	const char *option = getenv("HL_GC_ARENA_TRACKING");
	tracked = !(option && strcmp(option,"0") == 0);
	for(int i=0;i<COUNT;i+=4096) hl_add_root(&blocks[i]); // part of `blocks` is a root, the rest plain memory
	outside = (void**)hl_gc_alloc_raw(sizeof(void*) * 64);

	/* Nothing escapes: the release finds no reference, reuses the pages and takes the bytes out of the trigger. */
	{
		hl_gc_major();
		unsigned long long base = heap_bytes(), marks = collections();
		double since = hl_gc_allocated_since_collection();
		fill(&arena_a,COUNT,0);
		double filled = hl_gc_allocated_since_collection();
		if(!check(heap_bytes() > base + COUNT * 8,"the arena's blocks occupy pages")) goto done;
		int found = freed(&arena_a);
		if( tracked ) {
			if(!check(found == 0,"an arena nothing points into is released without a collection")) { fprintf(stderr,"found %d\n",found); goto done; }
			if(!check(heap_bytes() < base + (1 << 20),"its pages leave the heap")) goto done;
			if(!check(hl_gc_allocated_since_collection() < since + (filled - since) / 10,"what it allocated no longer counts toward a collection")) goto done;
		} else {
			if(!check(found == -1,"without tracking a release is not checked")) goto done;
			if(!check(hl_gc_allocated_since_collection() >= filled,"and its allocations still count")) goto done;
		}
		if(!check(collections() == marks,"no collection ran")) goto done;
		/* Many more, one after another: the pool serves them, so the heap does not grow. */
		unsigned long long peak = heap_bytes();
		for(int cycle=0;cycle<50;cycle++) {
			void *last = fill(&arena_b,COUNT,1);
			if(!check(chain_intact((void**)last,COUNT),"blocks from reused pages hold what was written")) goto done;
			last = NULL;
			int again = freed(&arena_b);
			if( tracked && !check(again == 0,"sequential arenas are released each time")) goto done;
			if( heap_bytes() > peak ) peak = heap_bytes();
		}
		if( tracked && !check(peak < base + (8 << 20),"sequential arenas reuse the same pages")) goto done;
	}

	/* A reference from a heap page outside the arena, written while it was open, keeps it; the blocks stay valid. */
	{
		void *last = fill(&arena_c,1000,1);
		outside[3] = last;
		last = NULL;
		if(!expect_kept(freed(&arena_c),"a pointer in a page outside the arena keeps it")) goto done;
		hl_gc_major();
		if(!check(chain_intact((void**)outside[3],1000),"what it kept survives a collection intact")) goto done;
		outside[3] = NULL;
		hl_gc_major();
	}

	/* A root. */
	{
		global_slot = fill(&arena_d,1000,1);
		if(!expect_kept(freed(&arena_d),"a root pointing into the arena keeps it")) goto done;
		hl_gc_major();
		if(!check(chain_intact((void**)global_slot,1000),"kept through a root, intact")) goto done;
		global_slot = NULL;
	}

	/* A stack slot of a frame older than the release. */
	{
		void *last = fill(&arena_e,1000,1);
		int found = freed_with_stack_slot(&arena_e,last);
		if(!check(found != -100,"the stack slot kept its value")) goto done;
		if(!expect_kept(found,"a stack slot pointing into the arena keeps it")) goto done;
		hl_gc_major();
		if(!check(chain_intact((void**)last,1000),"kept through the stack, intact")) goto done;
		last = NULL;
	}

	/* Nested arenas: an output placed in the enclosing arena that points into the inner one keeps the inner one;
	   without such a pointer the inner one goes, and the outer one after it. */
	{
		void *outer = hl_gc_arena_enter(&arena_f);
		void **made = (void**)hl_gc_alloc_raw(sizeof(void*) * 4);
		void *inner_last = fill(&arena_g,1000,1);
		made[0] = inner_last; // written into the outer arena's page while the inner one is open
		inner_last = NULL;
		hl_gc_arena_leave(outer);
		global_slot = made;
		made = NULL;
		if(!expect_kept(freed(&arena_g),"a pointer from the enclosing arena keeps the inner one")) goto done;
		global_slot = NULL;
		if(!check(freed(&arena_f) != -100,"the enclosing arena is released after")) goto done;
		void *outer2 = hl_gc_arena_enter(&arena_f);
		fill(&arena_g,1000,0);
		hl_gc_arena_leave(outer2);
		int inner = freed(&arena_g), enclosing = freed(&arena_f);
		if( tracked && !check(inner == 0 && enclosing == 0,"nested arenas nothing points into are both released")) goto done;
	}
	/* Type homes: a type homed outside any arena allocates there whatever arena is current, and one homed in an arena
	   allocates in it from inside another. */
	{
		static hl_type global_home, arena_home;
		global_home = hlt_bytes;
		arena_home = hlt_bytes;
		hl_gc_arena_set_home(&global_home,hl_gc_arena_global());
		hl_gc_arena_set_home(&arena_home,&arena_a);
		void *outer = hl_gc_arena_enter(&arena_a);
		hl_gc_arena_leave(outer);
		void *previous = hl_gc_arena_enter(&arena_b);
		global_slot = hl_gc_alloc_gen(&global_home,64,MEM_KIND_NOPTR);
		outside[5] = hl_gc_alloc_gen(&arena_home,64,MEM_KIND_NOPTR);
		fill(&arena_b,1000,0);
		hl_gc_arena_leave(previous);
		int current = freed(&arena_b);
		if( tracked && !check(current == 0,"objects of homed types are not the current arena's")) goto done;
		if(!expect_kept(freed(&arena_a),"an object homed in an arena is that arena's")) goto done;
		global_slot = NULL;
		outside[5] = NULL;
	}
	/* A table made outside that grows inside an arena grows in its own pages, so the arena is still released. */
	{
		table = hl_alloc_array(&hlt_i32,4);
		void *previous = hl_gc_arena_enter(&arena_c);
		for(int i=0;i<64;i++) hl_gc_alloc_raw(64);
		hl_array_reserve(table,100000);
		hl_gc_arena_leave(previous);
		int found = freed(&arena_c);
		if( tracked && !check(found == 0,"a table that grew inside an arena does not keep it")) goto done;
		table = NULL;
	}
	result = 0;
done:
	if( result == 0 ) {
		double released, kept, scan_ms, check_ms;
		hl_gc_arena_stats(&released,&kept,&scan_ms,&check_ms);
		printf("arenas released %.0f, kept %.0f, scan %.3f ms, check %.3f ms\n",released,kept,scan_ms,check_ms);
	}
	return result;
}
