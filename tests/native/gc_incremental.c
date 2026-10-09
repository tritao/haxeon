#include <hl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <time.h>

HL_API void hl_gc_enable(bool);
HL_API void hl_array_blit(varray*,int,varray*,int,int);
HL_API double hl_gc_collections(void);
HL_API double hl_gc_last_pause_micros(void);
static void **large, **parent, **newborn;
static void *interior;
static varray *retained_array;
// Deliberately outside the GC root set. Only the worker reads these addresses.
static void *hidden[24];
static vdynamic *retained_object, *copied_object;
static void *retained_map, *retained_map64;
static vclosure *retained_closure;
static vvirtual *retained_virtual;
static vdynamic *copied_virtual, *copied_inline_virtual;
static hl_module_context virtual_context;
static hl_type virtual_type = { HVIRTUAL };
static hl_type_virtual virtual_layout;
static hl_obj_field virtual_fields[2];
static hl_type closure_type = { HFUN };
static hl_type_fun closure_layout;
static hl_type *closure_args[] = { &hlt_bytes };
HL_API vdynamic *hl_obj_copy(vdynamic*);
HL_API bool hl_obj_delete_field(vdynamic*,int);
HL_API void *hl_hialloc(void);
HL_API void hl_hiset(void*,int,vdynamic*);
HL_API vdynamic *hl_higet(void*,int);
HL_API bool hl_hiremove(void*,int);
HL_API void *hl_hi64alloc(void);
HL_API void hl_hi64set(void*,int64,vdynamic*);
HL_API vdynamic *hl_hi64get(void*,int64);
static void closure_stub(void *value) { (void)value; }
static int finalized;
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	large = hl_gc_alloc_gen(NULL,16 << 20,MEM_KIND_RAW | MEM_ZERO);
	parent = hl_gc_alloc_gen(NULL,32 * sizeof(void*),MEM_KIND_RAW | MEM_ZERO);
	retained_array = hl_alloc_array(&hlt_dyn,4);
	retained_object = (vdynamic*)hl_alloc_dynobj();
	hl_dyn_setp(retained_object,hl_hash_utf8("first"),&hlt_bytes,NULL);
	retained_map = hl_hialloc();
	retained_map64 = hl_hi64alloc();
	// Populate old storage so mutation exercises overwrite as well as resizing.
	for(int i = 0; i < 20; i++) { hl_hiset(retained_map,i,NULL); hl_hi64set(retained_map64,i,NULL); }
	retained_virtual = hl_alloc_virtual(&virtual_type);
	for(int i = 0; i < 24; i++) {
		void **p = hl_gc_alloc_gen(NULL,3 * sizeof(void*),MEM_KIND_FINALIZER | MEM_ZERO);
		p[0] = (void*)finalize;
		p[2] = (void*)(size_t)(100 + i);
		hidden[i] = p;
	}
	hl_unregister_thread();
	return NULL;
}
static void *mutate(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	// Old unmarked objects become reachable through a previously scanned object,
	// an interior reference, and a black object allocated during the cycle.
	hl_gc_store_ref(&parent[0],hidden[0],&hlt_dyn);
	interior = (char*)hidden[1] + sizeof(void*);
	newborn = hl_gc_alloc_gen(NULL,32 * sizeof(void*),MEM_KIND_RAW | MEM_ZERO);
	for(int i = 2; i < 8; i++) hl_gc_store_ref(&newborn[i],hidden[i],&hlt_dyn);
	for(int i = 0; i < 4; i++) hl_gc_store_ref(&hl_aptr(retained_array,void*)[i],hidden[i+8],&hlt_dyn);
	// Exercise backing replacement, typed copies and both overlap directions
	// while these targets are reachable only from the array being mutated.
	hl_array_ensure(retained_array,15);
	for(int i = 4; i < 8; i++) hl_gc_store_ref(&hl_aptr(retained_array,void*)[i],hidden[i+8],&hlt_dyn);
	hl_array_blit(retained_array,8,retained_array,0,8);
	hl_array_blit(retained_array,1,retained_array,0,7);
	hl_gc_swap_values(&hl_aptr(retained_array,void*)[8],&hl_aptr(retained_array,void*)[15],sizeof(void*),&hlt_dyn);
	hl_gc_swap_values(&hl_aptr(retained_array,void*)[8],&hl_aptr(retained_array,void*)[15],sizeof(void*),&hlt_dyn);
	hl_gc_clear_values(&hl_aptr(retained_array,void*)[0],sizeof(void*),&hlt_dyn);
	// Dynamic storage expansion, deletion/compaction and copying.
	hl_dyn_setp(retained_object,hl_hash_utf8("first"),&hlt_bytes,hidden[16]);
	hl_dyn_setp(retained_object,hl_hash_utf8("second"),&hlt_bytes,hidden[17]);
	copied_object = hl_obj_copy(retained_object);
	hl_obj_delete_field(retained_object,hl_hash_utf8("first"));
	hl_obj_delete_field(retained_object,hl_hash_utf8("second"));
	for(int i = 20; i < 200; i++) { hl_hiset(retained_map,i,NULL); hl_hi64set(retained_map64,i,NULL); }
	hl_hiset(retained_map,1,(vdynamic*)hidden[18]);
	hl_hiset(retained_map,2,(vdynamic*)hidden[18]);
	hl_hiremove(retained_map,2);
	hl_hi64set(retained_map64,1,(vdynamic*)hidden[19]);
	retained_closure = hl_alloc_closure_ptr(&closure_type,closure_stub,hidden[20]);
	vvirtual *inline_source = hl_alloc_virtual(&virtual_type);
	hl_dyn_setp((vdynamic*)inline_source,virtual_fields[0].hashed_name,&hlt_bytes,hidden[23]);
	copied_inline_virtual = hl_obj_copy((vdynamic*)inline_source);
	// Materialize inline virtual data, then expand storage and remap the view.
	hl_dyn_setp((vdynamic*)retained_virtual,virtual_fields[0].hashed_name,&hlt_bytes,hidden[21]);
	vdynamic *materialized = hl_virtual_make_value(retained_virtual);
	hl_dyn_setp(materialized,hl_hash_utf8("extra"),&hlt_bytes,hidden[22]);
	hl_dyn_setp(materialized,virtual_fields[1].hashed_name,&hlt_bytes,hidden[22]);
	copied_virtual = hl_obj_copy(materialized);
	hl_obj_delete_field(materialized,hl_hash_utf8("extra"));
	hl_unregister_thread();
	return NULL;
}
static void *stabilize(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	// The ordinary HashLink marker only accepts exact heap-field pointers.
	parent[2] = hidden[1];
	hl_unregister_thread();
	return NULL;
}
static void *pressure(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	hl_gc_alloc_gen(NULL,32 << 20,MEM_KIND_NOPTR | MEM_ZERO);
	hl_unregister_thread();
	return NULL;
}
static int worker(void *(*fn)(void*)) {
	pthread_t thread;
	if( pthread_create(&thread,NULL,fn,NULL) ) return 0;
	hl_blocking(true);
	int result = pthread_join(thread,NULL);
	hl_blocking(false);
	return result == 0;
}
static int break_tracking(const char *name) {
	char path[64], target[256];
	for(int fd = 3; fd < 1024; fd++) {
		snprintf(path,sizeof(path),"/proc/self/fd/%d",fd);
		ssize_t n = readlink(path,target,sizeof(target)-1);
		if( n < 0 ) continue;
		target[n] = 0;
		if( strstr(target,name) ) { close(fd); return 1; }
	}
	return 0;
}
static int complete(void) {
	for(int i = 0; i < 10000; i++) if( hl_gc_step(1000.0) ) return i + 1;
	return 0;
}
int main(int argc, char **argv) {
	int marker = 0;
	hl_global_init();
	hl_register_thread(&marker);
	hl_gc_enable(false);
	virtual_fields[0].t = virtual_fields[1].t = &hlt_bytes;
	virtual_fields[0].hashed_name = hl_hash_utf8("ref");
	virtual_fields[1].hashed_name = hl_hash_utf8("other");
	virtual_layout.fields = virtual_fields; virtual_layout.nfields = 2;
	virtual_type.virt = &virtual_layout;
	hl_init_virtual(&virtual_type,&virtual_context);
	closure_layout.args = closure_args; closure_layout.nargs = 1; closure_layout.ret = &hlt_void;
	closure_type.fun = &closure_layout;
	if( !hl_gc_incremental_supported() ) { puts("SKIP: kernel soft-dirty tracking unavailable"); return 77; }
	if( getenv("HL_GC_TEST_UNSET_VALIDATION") ) unsetenv("HL_GC_INCREMENTAL_VALIDATE");
	hl_add_root(&large); hl_add_root(&parent); hl_add_root(&newborn); hl_add_root(&interior); hl_add_root(&retained_array);
	hl_add_root(&retained_object); hl_add_root(&copied_object);
	hl_add_root(&retained_map); hl_add_root(&retained_map64); hl_add_root(&retained_closure);
	hl_add_root(&retained_virtual); hl_add_root(&copied_virtual); hl_add_root(&copied_inline_virtual);
	if( !worker(setup) ) return 1;
	if( hl_gc_step(0) || hl_gc_step(-1) || hl_gc_step(NAN) || hl_gc_step(INFINITY) || hl_gc_incremental_pending() ) return 2;
	double before = hl_gc_collections();
	if( hl_gc_step(0.001) || !hl_gc_incremental_pending() || !hl_gc_incremental_preparing() || hl_gc_collections() != before ) return 3;
	if( !worker(mutate) ) return 4;
	if( argc > 1 ) {
		if( !worker(stabilize) ) return 5;
		if( strcmp(argv[1],"pressure") == 0 ) {
			if( !worker(pressure) ) return 14;
		} else if( !break_tracking(argv[1]) ) return 5;
	}
	int slices = complete();
	if( !slices || hl_gc_incremental_pending() || hl_gc_collections() != before + 1 ) return 6;
	hl_gc_incremental_metrics metrics;
	hl_gc_incremental_stats(&metrics);
	if( metrics.dirty_pages || metrics.mark_objects || metrics.cycle_age_micros != 0 || metrics.cycles_started != 1 ) return 22;
	if( argc == 1 ) {
		if( metrics.cycles_completed != 1 || metrics.pressure_fallbacks || metrics.tracking_fallbacks || !(metrics.last_cycle_micros > 0) ) return 23;
	} else if( strcmp(argv[1],"pressure") == 0 ) {
		if( metrics.cycles_completed || metrics.pressure_fallbacks != 1 || metrics.tracking_fallbacks ) return 24;
	} else if( metrics.cycles_completed || metrics.pressure_fallbacks || metrics.tracking_fallbacks != 1 ) return 25;
	if( finalized || ((void**)parent[0])[2] != (void*)100 || ((void**)newborn[7])[2] != (void*)107 || retained_array->size != 16 || ((void**)hl_aptr(retained_array,void*)[15])[2] != (void*)115 ) return 7;
	if( hl_dyn_getp(copied_object,hl_hash_utf8("first"),&hlt_bytes) != hidden[16] ||
		hl_dyn_getp(copied_object,hl_hash_utf8("second"),&hlt_bytes) != hidden[17] ||
		hl_higet(retained_map,1) != hidden[18] || hl_hi64get(retained_map64,1) != hidden[19] ||
		retained_closure->value != hidden[20] ||
		hl_dyn_getp((vdynamic*)retained_virtual,virtual_fields[0].hashed_name,&hlt_bytes) != hidden[21] ||
		hl_dyn_getp(copied_virtual,virtual_fields[1].hashed_name,&hlt_bytes) != hidden[22] ||
		hl_dyn_getp(copied_inline_virtual,virtual_fields[0].hashed_name,&hlt_bytes) != hidden[23] ) return 16;
	if( !worker(stabilize) ) return 13;
	// Explicit full collection must safely cancel an unfinished cycle and its queue.
	if( argc == 1 ) {
		if( hl_gc_step(0.001) || !hl_gc_incremental_pending() ) return 8;
		hl_gc_major();
		if( hl_gc_incremental_pending() || finalized ) { fprintf(stderr,"abort: pending=%d finalized=%d\n",hl_gc_incremental_pending(),finalized); return 9; }
		if( !complete() || finalized ) return 10;
		// Also cancel after preparation has yielded to marking, not just while
		// some pages still carry the previous collection's lazy-sweep bitmap.
		if( hl_gc_step(0.001) ) return 17;
		int preparation_slices = 0;
		while( hl_gc_incremental_preparing() ) {
			if( hl_gc_step(0.001) || ++preparation_slices > 100000 ) return 18;
		}
		if( !hl_gc_incremental_pending() ) return 19;
		hl_gc_major();
		if( hl_gc_incremental_pending() || hl_gc_incremental_preparing() || finalized ) return 20;
		if( !complete() || finalized ) return 21;
	} else if( strcmp(argv[1],"pressure") == 0 ) {
		if( slices != 1 || !hl_gc_incremental_supported() ) return 15;
	} else if( hl_gc_incremental_supported() ) return 11;
	// Dropped objects are eventually finalized, exactly once. Clear hidden addresses
	// and use a worker so conservative registers in main never contain a target.
	memset(hidden,0,sizeof(hidden));
	large = parent = newborn = NULL;
	interior = NULL;
	retained_array = NULL;
	retained_object = copied_object = copied_virtual = copied_inline_virtual = NULL;
	retained_map = retained_map64 = NULL; retained_closure = NULL; retained_virtual = NULL;
	for(int i = 0; i < 4; i++) hl_gc_major();
	if( finalized != 24 ) { fprintf(stderr,"finalized %d/24\n",finalized); return 12; }
	printf("PASS: incremental mutation, interior roots, black allocations, arrays, dynamic objects, virtuals, maps, closures, abort, finalizers; %d slices\n",slices);
	hl_unregister_thread(); hl_free(&virtual_context.alloc); hl_global_free();
	return 0;
}
