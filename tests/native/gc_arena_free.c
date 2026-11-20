#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* An arena released without a collection (hl_gc_arena_free): its pages are reused at once when nothing outside points into
   it, and handed to the collector when something does, whether the reference is in a page of the heap, a root or a
   stack slot. With HL_GC_ARENA_TRACKING=0 no release is checked and every arena goes to the collector. */

HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);
HL_PRIM double hl_gc_allocated_since_collection(void);
HL_API void *hl_hballoc(void);

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
static int arena_a, arena_b, arena_c, arena_d, arena_e, arena_f, arena_g, arena_h, arena_i;

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

/* A chain of `count` arrays in `arena`, each holding the one made before it, and the last returned. */
static NOINLINE varray *array_chain(void *arena, int count) {
	void *previous = hl_gc_arena_enter(arena);
	varray *last = NULL;
	for(int i=0;i<count;i++) {
		varray *node = hl_alloc_array(&hlt_array,1);
		hl_aptr(node,varray*)[0] = last;
		last = node;
	}
	hl_gc_arena_leave(previous);
	return last;
}

static int array_chain_intact(varray *last, int count) {
	int n = 0;
	while( last ) { n++; last = hl_aptr(last,varray*)[0]; }
	return n == count;
}

static hl_type map_type, closure_type;

/* Writes the address of a block of `arena` into `bytes` and returns it disguised, so no stack word holds it. */
static NOINLINE uintptr_t spell_address(void *arena, void **bytes) {
	varray *inside = array_chain(arena,10);
	bytes[2] = inside;
	return (uintptr_t)inside ^ 0x5a5a;
}

/* In `arena`: an array holding itself, bytes, a map and a raw block, returned copied out of it. */
static NOINLINE varray *copied_out(void *arena) {
	void *previous = hl_gc_arena_enter(arena);
	varray *self = hl_alloc_array(&hlt_array,1);
	hl_aptr(self,varray*)[0] = self;
	varray *bytes = hl_alloc_array(&hlt_bytes,2);
	unsigned char *data = (unsigned char*)hl_gc_alloc_noptr(32);
	for(int b=0;b<32;b++) data[b] = (unsigned char)b;
	hl_aptr(bytes,unsigned char*)[0] = data;
	varray *maps = hl_alloc_array(&map_type,1);
	void *map = hl_hballoc();
	for(int k=0;k<40;k++) {
		uchar key[8] = {'k',(uchar)('a' + k % 26),(uchar)('a' + k / 26),0};
		uchar *stored = (uchar*)hl_gc_alloc_noptr(sizeof(key));
		memcpy(stored,key,sizeof(key));
		int value = k;
		hl_hbset_n(map,stored,3,hl_make_dyn(&value,&hlt_i32));
	}
	hl_aptr(maps,void*)[0] = map;
	// A map boxed in a Dynamic, as a table of references stores one.
	varray *boxes = hl_alloc_array(&hlt_dyn,1);
	vdynamic *box = (vdynamic*)hl_gc_alloc_gen(&map_type,sizeof(vdynamic),MEM_KIND_DYNAMIC | MEM_ZERO);
	box->t = &map_type;
	box->v.ptr = map;
	hl_aptr(boxes,vdynamic*)[0] = box;
	varray *outer = hl_alloc_array(&hlt_array,4);
	hl_aptr(outer,varray*)[0] = self;
	hl_aptr(outer,varray*)[1] = bytes;
	hl_aptr(outer,varray*)[2] = maps;
	hl_aptr(outer,varray*)[3] = boxes;
	varray *copy = (varray*)hl_gc_arena_copy((vdynamic*)outer,arena,hl_gc_arena_global());
	hl_gc_arena_leave(previous);
	return copy;
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

	/* A byte block that spells an arena's address is no reference, and an evacuating release never changes it. (Whether
	   the arena is released here depends on what stale words this C frame keeps, so only the bytes are checked.) */
	{
		hl_gc_arena_set_evacuation(true);
		void **bytes = (void**)hl_gc_alloc_noptr(sizeof(void*) * 4);
		outside[10] = bytes;
		uintptr_t spelled = spell_address(&arena_i,bytes);
		freed(&arena_i);
		hl_gc_arena_set_evacuation(false);
		if(!check(((uintptr_t)bytes[2] ^ 0x5a5a) == spelled,"a byte block's words are never rewritten")) goto done;
		outside[10] = NULL;
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
	/* Copying out: what a value reaches inside an arena is copied along the layouts of typed blocks and registered untyped
	   ones (a map's tables), and the arena then has nothing outside pointing in. */
	{
		map_type.kind = HABSTRACT;
		map_type.abs_name = USTR("hl_bytes_map");
		global_slot = copied_out(&arena_d);
		varray *copy = (varray*)global_slot, *self = hl_aptr(copy,varray*)[0];
		if(!check(hl_gc_arena_owner_of(copy) == hl_gc_arena_global() && hl_aptr(self,varray*)[0] == self,"a copy is made outside the arena, its cycle kept")) goto done;
		copy = self = NULL;
		int found = freed(&arena_d);
		if( tracked && !check(found == 0,"an arena whose result was copied out is released")) goto done;
		hl_gc_major();
		copy = (varray*)global_slot;
		unsigned char *data = hl_aptr(hl_aptr(copy,varray*)[1],unsigned char*)[0];
		void *map = hl_aptr(hl_aptr(copy,varray*)[2],void*)[0];
		uchar key[8] = {'k','n','a',0};
		vdynamic *value = hl_hbget_n(map,key,3);
		if(!check(data[7] == 7 && data[31] == 31 && value && value->v.i == 13,"the copy, its bytes and its map survive the release and a collection")) goto done;
		vdynamic *box = hl_aptr(hl_aptr(copy,varray*)[3],vdynamic*)[0];
		if(!check(box->v.ptr == map,"a boxed map is copied with the map it holds")) goto done;
		copy = NULL;
		global_slot = NULL;
	}

	/* An evacuating release copies out what typed fields outside the arena point to, and releases it; a word of an untyped
	   block, a root, a stack word only keep it. A word that merely spells an address is never rewritten. */
	{
		hl_gc_arena_set_evacuation(true);
		closure_type.kind = HFUN;
		vclosure *closure = (vclosure*)hl_gc_alloc_gen(&closure_type,sizeof(vclosure),MEM_KIND_DYNAMIC | MEM_ZERO);
		closure->t = &closure_type;
		closure->hasValue = 1;
		global_slot = closure;
		closure->value = array_chain(&arena_e,1000);
		closure = NULL;
		int from_field = freed(&arena_e);
		if( tracked && !check(from_field == 0,"a typed field into an arena is evacuated")) goto done;
		hl_gc_major();
		if(!check(array_chain_intact((varray*)((vclosure*)global_slot)->value,1000),"evacuated blocks are intact")) goto done;
		global_slot = NULL;
		/* An untyped block and a byte block outside, each holding the arena's address as a plain word. */
		void **untyped = (void**)hl_gc_alloc_raw(sizeof(void*) * 4);
		void **bytes = (void**)hl_gc_alloc_noptr(sizeof(void*) * 4);
		outside[8] = untyped;
		outside[9] = bytes;
		varray *inside = array_chain(&arena_f,10);
		untyped[1] = inside;
		bytes[1] = inside;
		int from_untyped = freed(&arena_f);
		if(!expect_kept(from_untyped,"a word of an untyped block keeps an arena instead of being evacuated")) goto done;
		if(!check(untyped[1] == (void*)inside && bytes[1] == (void*)inside,"words of untyped and byte blocks are never rewritten")) goto done;
		inside = NULL;
		untyped = bytes = NULL;
		outside[8] = outside[9] = NULL;
		global_slot = array_chain(&arena_g,10);
		if(!expect_kept(freed(&arena_g),"a root keeps an arena instead of being evacuated")) goto done;
		global_slot = NULL;
		varray *last = array_chain(&arena_h,1000);
		int found = freed_with_stack_slot(&arena_h,last);
		if(!expect_kept(found,"a stack word still keeps an arena")) goto done;
		last = NULL;
		hl_gc_arena_set_evacuation(false);
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
