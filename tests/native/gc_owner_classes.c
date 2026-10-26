#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The warning given when the limit is first passed goes to stderr, once; the script that runs this checks for it.

   An owner has pages of its own for as long as it is registered, a limited number of owners can have that at once, and
   the rest share one set of pages. Sharing may delay the retirement of an owner and must never allow it early. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#else
#	define NOINLINE __attribute__((noinline))
#endif

#define OWNERS 20
#define PER_OWNER 10
#define FILLER 200000
static int owners[OWNERS];
static void *slots[OWNERS][PER_OWNER];
static void *filler[FILLER];

static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}

static NOINLINE void scrub_stack(void) {
	volatile char junk[16384];
	for(int i=0;i<(int)sizeof(junk);i++) junk[i] = 0;
}

static int live(void *owner) {
	scrub_stack();
	return hl_gc_owner_live_count(owner);
}

static unsigned long long heap_bytes(void) {
	unsigned long long a,b,c,d,e;
	hl_gc_profile_stats(&a,&b,&c,&d,&e);
	return c;
}

static NOINLINE void hold(int owner, int count, int size) {
	for(int i=0;i<count;i++) {
		hl_add_root(&slots[owner][i]);
		slots[owner][i] = hl_gc_alloc_gen_owner(NULL,size + i * 8,MEM_KIND_RAW|MEM_ZERO,&owners[owner]);
	}
}

static NOINLINE void let_go(int owner, int count) {
	for(int i=0;i<count;i++) {
		hl_remove_root(&slots[owner][i]);
		slots[owner][i] = NULL;
	}
}

static NOINLINE void fill(int owner) {
	for(int i=0;i<FILLER;i++) {
		hl_add_root(&filler[i]);
		filler[i] = hl_gc_alloc_gen_owner(NULL,16,MEM_KIND_NOPTR|MEM_ZERO,&owners[owner]);
	}
}

static NOINLINE void empty(void) {
	for(int i=0;i<FILLER;i++) {
		hl_remove_root(&filler[i]);
		filler[i] = NULL;
	}
}

int main(void) {
	int marker = 0, result = 1;
	hl_global_init();
	hl_register_thread(&marker);

	/* Far more owners come and go than there are classes: each one is counted exactly and gives its class back. */
	for(int cycle=0;cycle<60;cycle++) {
		int owner = cycle % OWNERS;
		hl_gc_owner_register(&owners[owner]);
		hold(owner,PER_OWNER,16);
		if(!check(live(&owners[owner]) == PER_OWNER,"a registered owner counts its blocks")) goto done;
		let_go(owner,PER_OWNER);
		if(!check(live(&owners[owner]) == 0,"and none once they are unreferenced")) goto done;
		hl_gc_owner_release(&owners[owner]);
		if(!check(live(&owners[owner]) == 0,"a released owner counts nothing")) goto done;
	}

	/* Releasing an owner returns its pages, whatever the empty-page cache would keep. */
	{
		unsigned long long base, peak, after;
		hl_gc_major();
		base = heap_bytes();
		hl_gc_owner_register(&owners[0]);
		fill(0);
		peak = heap_bytes();
		if(!check(peak > base + FILLER * 16 / 2,"the owner's blocks occupy pages")) goto done;
		empty();
		if(!check(live(&owners[0]) == 0,"the blocks are gone")) goto done;
		hl_gc_owner_release(&owners[0]);
		after = heap_bytes();
		if(!check(after < base + (1 << 20),"release returns the owner's pages")) goto done;
	}

	/* More owners than classes: every owner is counted at least exactly, the ones past the limit together. */
	for(int owner=0;owner<OWNERS;owner++) {
		hl_gc_owner_register(&owners[owner]);
		hold(owner,PER_OWNER,16);
	}
	for(int owner=0;owner<OWNERS;owner++)
		if(!check(live(&owners[owner]) >= PER_OWNER,"no owner is ever under-counted")) goto done;
	if(!check(live(&owners[0]) == PER_OWNER,"owners with a class of their own are exact")) goto done;
	if(!check(live(&owners[OWNERS-1]) <= PER_OWNER * (OWNERS - 16),"the shared class holds only the owners past the limit")) goto done;
	let_go(OWNERS-1,PER_OWNER);
	if(!check(live(&owners[OWNERS-2]) >= PER_OWNER,"a shared owner still counts its neighbours")) goto done;
	for(int owner=0;owner<OWNERS-1;owner++) let_go(owner,PER_OWNER);
	for(int owner=0;owner<OWNERS;owner++)
		if(!check(live(&owners[owner]) == 0,"nothing is left once everything is unreferenced")) goto done;

	/* An owner with live blocks keeps its class when released, and they stay valid and counted. */
	hold(1,PER_OWNER,16);
	hl_gc_owner_release(&owners[1]);
	if(!check(live(&owners[1]) == PER_OWNER,"release does not touch live blocks")) goto done;
	let_go(1,PER_OWNER);
	if(!check(live(&owners[1]) == 0,"and they can still be dropped")) goto done;

	for(int owner=0;owner<OWNERS;owner++) hl_gc_owner_release(&owners[owner]);
	/* Everything was handed back, so new owners have classes of their own again and are counted exactly. */
	hold(2,5,16);
	hold(3,PER_OWNER,16);
	if(!check(live(&owners[2]) == 5 && live(&owners[3]) == PER_OWNER,"classes are free again")) goto done;
	let_go(2,5);
	let_go(3,PER_OWNER);
	hl_gc_owner_release(NULL);
	{
		int never = 0;
		hl_gc_owner_release(&never);
	}
	result = 0;
done:
	return result;
}
