#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Allocations for an owner are as cheap as any other small allocation: they come out of the thread's buffer without
   the global lock, and are still counted for the owner they were made for. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#	define ATOMIC_ADD(p,v) _InterlockedExchangeAdd((volatile long*)(p),(v))
#else
#	define NOINLINE __attribute__((noinline))
#	define ATOMIC_ADD(p,v) __sync_fetch_and_add((p),(v))
#endif

#define WORKERS 4
#define KEPT 1000
static int owner;
static void *kept[WORKERS][KEPT];
static volatile int finished;

static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}

static unsigned long long allocation_count(void) {
	unsigned long long a,b,c,d,e;
	hl_gc_profile_stats(&a,&b,&c,&d,&e);
	return b;
}

static NOINLINE void scrub_stack(void) {
	volatile char junk[16384];
	for(int i=0;i<(int)sizeof(junk);i++) junk[i] = 0;
}

static void worker(void *argument) {
	int index = (int)(intptr_t)argument;
	for(int i=0;i<KEPT;i++) {
		/* root the slot first: a collection between the allocation and the registration would not see the block */
		hl_add_root(&kept[index][i]);
		kept[index][i] = hl_gc_alloc_gen_owner(NULL,24,MEM_KIND_RAW|MEM_ZERO,&owner);
	}
	for(int i=0;i<200000;i++) {
		unsigned char *p = hl_gc_alloc_gen_owner(NULL,16 + (i & 3) * 8,MEM_KIND_RAW|MEM_ZERO,&owner);
		if(p[0] != 0 || p[8] != 0) fprintf(stderr,"FAIL: owned block is not zeroed\n");
		p[0] = 0xa5;
		p[8] = 0xa5;
	}
	ATOMIC_ADD(&finished,1);
}

static NOINLINE int zero_fill(void) {
	/* Zero filling and padding behave as for unowned blocks, including on blocks that were used and swept before. */
	for(int round=0;round<3;round++) {
		for(int size=1;size<=40;size++)
			for(int kind=MEM_KIND_DYNAMIC;kind<=MEM_KIND_NOPTR;kind++) {
				unsigned char *p = hl_gc_alloc_gen_owner(NULL,size,kind|MEM_ZERO,&owner);
				int allocated = hl_gc_get_memsize(p);
				if(!check(allocated >= size,"owned block size")) return 0;
				for(int i=0;i<allocated;i++) if(!check(p[i] == 0,"owned block is zeroed")) return 0;
				memset(p,0xa5,allocated);
				if(kind == MEM_KIND_RAW) {
					p = hl_gc_alloc_gen_owner(NULL,size,kind,&owner);
					allocated = hl_gc_get_memsize(p);
					for(int i=size;i<allocated;i++) if(!check(p[i] == 0,"owned pointer padding is cleared")) return 0;
					memset(p,0xa5,allocated);
				}
			}
		hl_gc_major();
	}
	return 1;
}

int main(void) {
	int marker = 0, result = 1;
	unsigned long long before, after;
	hl_global_init();
	hl_register_thread(&marker);

	/* Once the thread holds a run of blocks, owned allocations neither count as separate allocations nor take the lock. */
	hl_gc_alloc_gen_owner(NULL,16,MEM_KIND_NOPTR|MEM_ZERO,&owner); /* registers the owner */
	hl_gc_alloc_gen_owner(NULL,16,MEM_KIND_NOPTR|MEM_ZERO,&owner); /* reserves the first run */
	before = allocation_count();
	for(int i=0;i<50;i++) hl_gc_alloc_gen_owner(NULL,16,MEM_KIND_NOPTR|MEM_ZERO,&owner);
	after = allocation_count();
	if(!check(after == before,"owned small allocations are served from the thread's buffer")) goto done;

	if(!zero_fill()) goto done;

	/* Threads allocate for the owner while another one collects and counts. */
	for(int i=0;i<WORKERS;i++) hl_thread_start(worker,(void*)(intptr_t)i,true);
	while(finished < WORKERS) {
		hl_gc_major();
		if(!check(hl_gc_owner_live_count(&owner) >= 0,"count while threads allocate")) goto done;
		hl_thread_yield();
	}
	scrub_stack();
	{
		int counted = hl_gc_owner_live_count(&owner);
		if(counted != WORKERS * KEPT) fprintf(stderr,"counted %d, expected %d\n",counted,WORKERS * KEPT);
	}
	if(!check(hl_gc_owner_live_count(&owner) == WORKERS * KEPT,"every kept block of every thread is counted, nothing else")) goto done;
	result = 0;
done:
	return result;
}
