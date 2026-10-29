#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* What a module still owns is counted by hl_gc_owner_live_count and decides when it can be retired. These checks use only
   the allocation entry points, so they hold for any way of keeping the count. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);

#define MAX_SLOTS 4096
static void *slots_a[MAX_SLOTS], *slots_b[MAX_SLOTS], *slots_plain[MAX_SLOTS];
static int count_a, count_b, count_plain;
static int owner_a, owner_b;

static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#else
#	define NOINLINE __attribute__((noinline))
#endif

/* The collector is conservative about the stack, so overwrite what earlier calls left behind before counting survivors. */
static NOINLINE void scrub_stack(void) {
	volatile char junk[16384];
	for(int i=0;i<(int)sizeof(junk);i++) junk[i] = 0;
}

static NOINLINE void rooted(void **slots, int *count, void *owner, int size, int flags) {
	void *ptr = hl_gc_alloc_gen_owner(NULL,size,flags|MEM_ZERO,owner);
	slots[*count] = ptr;
	hl_add_root(&slots[*count]);
	(*count)++;
}

static NOINLINE int fill(void) {
	/* fixed-size partitions, variable-size partitions, blocks beyond the variable ones, and every kind */
	static const int sizes[] = {1, 8, 16, 24, 40, 48, 100, 500, 4000, 70000, 3 << 20};
	for(int s=0;s<(int)(sizeof(sizes)/sizeof(sizes[0]));s++)
		for(int kind=MEM_KIND_DYNAMIC;kind<=MEM_KIND_FINALIZER;kind++) {
			int size = sizes[s];
			/* the finalizer sweep reads the size table, which a block of its own page does not have */
			if(kind == MEM_KIND_FINALIZER && (size < 2*(int)sizeof(void*) || size >= (1 << 20))) continue;
			int copies = size > 100000 ? 1 : size > 4000 ? 3 : 40;
			for(int i=0;i<copies;i++) {
				rooted(slots_a,&count_a,&owner_a,size,kind);
				rooted(slots_b,&count_b,&owner_b,size,kind);
				rooted(slots_plain,&count_plain,NULL,size,kind);
				/* garbage of each owner, to be collected */
				hl_gc_alloc_gen_owner(NULL,size,kind|MEM_ZERO,&owner_a);
				hl_gc_alloc_gen_owner(NULL,size,kind|MEM_ZERO,&owner_b);
			}
		}
	return count_a < MAX_SLOTS && count_b < MAX_SLOTS && count_plain < MAX_SLOTS;
}

static NOINLINE void drop(void **slots, int from, int to) {
	for(int i=from;i<to;i++) {
		hl_remove_root(&slots[i]);
		slots[i] = NULL;
	}
}

static int live(void *owner) {
	scrub_stack();
	return hl_gc_owner_live_count(owner);
}

int main(void) {
	int marker = 0, result = 1;
	hl_global_init();
	hl_register_thread(&marker);
	if(!check(fill(),"slots")) goto done;
	if(!check(live(&owner_a) == count_a,"owner A counts exactly its rooted blocks")) goto done;
	if(!check(live(&owner_b) == count_b,"owner B counts exactly its rooted blocks")) goto done;
	int half_a = count_a / 2;
	drop(slots_a,0,half_a);
	if(!check(live(&owner_a) == count_a - half_a,"dropped blocks leave the count")) goto done;
	if(!check(live(&owner_b) == count_b,"the other owner is unaffected by a drop")) goto done;
	drop(slots_plain,0,count_plain);
	if(!check(live(&owner_b) == count_b,"unowned blocks are never counted")) goto done;
	drop(slots_a,half_a,count_a);
	drop(slots_b,0,count_b);
	if(!check(live(&owner_a) == 0,"owner A has nothing left")) goto done;
	if(!check(live(&owner_b) == 0,"owner B has nothing left")) goto done;
	if(!check(hl_gc_owner_live_count(NULL) == 0,"no owner counts nothing")) goto done;
	{
		int never = 0;
		if(!check(hl_gc_owner_live_count(&never) == 0,"an owner that never allocated counts nothing")) goto done;
	}
	result = 0;
done:
	return result;
}
