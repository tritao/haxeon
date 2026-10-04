#include <hl.h>
#include <stdio.h>
#include <string.h>

HL_API int hl_gc_get_flags(void);
HL_API void hl_gc_set_flags(int flags);
HL_API void hl_gc_set_profile_allocation_callback(void (*callback)(hl_type*,int,int,void*));
HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);
HL_API void hl_gc_census_start(int every);
HL_API void hl_gc_census_stop(void);
HL_API void hl_gc_census_dump(const char *filename);
static int callback_count, callback_bad;
static void allocation_callback(hl_type *type, int size, int allocated, void *caller) {
	callback_count++;
	if(type != NULL || size != 17 || allocated < size || caller == NULL) callback_bad++;
}
static int check(int success, const char *label) {
	if(!success) fprintf(stderr,"FAIL: %s\n",label);
	return success;
}
int main(int argc, char **argv) {
	int stack_marker = 0, owner = 0, flags, result = 1;
	unsigned long long a,b,c,before,after,d;
	void *owned;
	void *anchors[10];
	if(argc != 2) return 2;
	hl_global_init();
	hl_register_thread(&stack_marker);
	flags=hl_gc_get_flags();
	/* Keep each size/kind page alive so later rounds reuse dirty freed blocks. */
	for(int part=0;part<5;part++) for(int kind=0;kind<2;kind++) {
		int index=part*2+kind;
		anchors[index]=hl_gc_alloc_gen(NULL,(part+1)*(int)sizeof(void*),(kind ? MEM_KIND_NOPTR : MEM_KIND_RAW)|MEM_ZERO);
		hl_add_root(&anchors[index]);
	}
	for(int round=0;round<4;round++) {
		for(int size=1;size<=40;size++) {
			for(int kind=MEM_KIND_RAW;kind<=MEM_KIND_NOPTR;kind++) {
				unsigned char *ptr=hl_gc_alloc_gen(NULL,size,kind|MEM_ZERO);
				int allocated=hl_gc_get_memsize(ptr);
				if(!check(allocated>=size,"small allocation size")) goto done;
				for(int i=0;i<allocated;i++) if(!check(ptr[i]==0,"zeroed payload and padding")) goto done;
				memset(ptr,0xa5,allocated);
				if(kind==MEM_KIND_RAW) {
					ptr=hl_gc_alloc_gen(NULL,size,kind);
					allocated=hl_gc_get_memsize(ptr);
					for(int i=size;i<allocated;i++) if(!check(ptr[i]==0,"pointer padding is cleared without MEM_ZERO")) goto done;
					memset(ptr,0xa5,allocated);
				}
			}
		}
		hl_gc_major();
	}
	if(!check(hl_gc_alloc_gen(NULL,0,MEM_KIND_RAW)==NULL,"zero size")) goto done;
	/* Warm this size class, then enable the callback while a run is still ready. */
	hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_set_profile_allocation_callback(allocation_callback);
	for(int i=0;i<100;i++) hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_set_profile_allocation_callback(NULL);
	if(!check(callback_count==100 && callback_bad==0,"allocation callback observes every allocation")) goto done;
	owned=hl_gc_alloc_gen_owner(NULL,17,MEM_KIND_RAW|MEM_ZERO,&owner);
	hl_add_root(&owned);
	if(!check(hl_gc_owner_live_count(&owner)==1,"owned allocations retain their owner")) goto done;
	hl_remove_root(&owned);
	hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_profile_stats(&a,&b,&c,&before,&d);
	hl_gc_set_flags(flags|8); /* GC_FORCE_MAJOR */
	hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_profile_stats(&a,&b,&c,&after,&d);
	hl_gc_set_flags(flags);
	if(!check(after>before,"force-major bypasses a ready TLAB")) goto done;
	hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_census_start(0);
	for(int i=0;i<128;i++) hl_gc_alloc_gen(NULL,17,MEM_KIND_NOPTR|MEM_ZERO);
	hl_gc_census_dump(argv[1]);
	hl_gc_census_stop();
	result=0;
done:
	hl_gc_set_profile_allocation_callback(NULL);
	hl_gc_set_flags(flags);
	for(int i=0;i<10;i++) hl_remove_root(&anchors[i]);
	hl_global_free();
	if(result==0) puts("PASS: small allocation zeroing, padding, callback, owner, force-major and census guards");
	return result;
}
