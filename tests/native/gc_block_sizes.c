/* Exercise shift/division block lookup through interior roots and exact heap
 * edges. Sizes cover fixed/variable classes and dedicated large allocations. */
#include <hl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
HL_API void hl_gc_enable(bool);
static const int sizes[]={8,16,24,32,40,64,128,192,8192,1048568,1048576,1114112};
#define COUNT ((int)(sizeof(sizes)/sizeof(sizes[0])))
static void *roots[COUNT];
static void **invalid_holder;
static int finalized, verified;
static bool interior_roots=true;
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 for(int i=0;i<COUNT;i++) {
  void **object=hl_gc_alloc_gen(NULL,sizes[i],MEM_KIND_RAW|MEM_ZERO);
  void **target=hl_gc_alloc_gen(NULL,3*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
  target[0]=(void*)finalize; target[2]=(void*)(uintptr_t)(i+42);
  hl_gc_store_ref(object,target,&hlt_dyn);
  roots[i]=(char*)object+1; // Unaligned interior ROOT is accepted.
 }
 invalid_holder=hl_gc_alloc_gen(NULL,8*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 void **invalid=hl_gc_alloc_gen(NULL,3*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
 invalid[0]=(void*)finalize;
 hl_gc_store_ref(invalid_holder,(char*)invalid+1,&hlt_dyn); // Unaligned interior heap edge.
 hl_gc_store_ref(invalid_holder+1,(char*)invalid+sizeof(void*),&hlt_dyn); // Aligned interior, same cached page.
 hl_unregister_thread(); return NULL;
}
static void *verify(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 verified=1;
 for(int i=0;i<COUNT;i++) {
  void **object=(void**)((char*)roots[i]-(interior_roots?1:0)), **target=object[0];
  if(target[2]!=(void*)(uintptr_t)(i+42)) verified=0;
 }
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t t; if(pthread_create(&t,NULL,fn,NULL)) hl_fatal("worker");
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
}
int main(void) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 for(int i=0;i<COUNT;i++) hl_add_root(&roots[i]);
 hl_add_root(&invalid_holder); worker(setup);
 // Incremental heap fields use exact starts; the rejected target is finalized.
 int steps=0; while(!hl_gc_step(100)) if(++steps>100000) return 2;
 if(finalized!=1) return 3;
 worker(verify); if(!verified) return 4;
 // Ordinary explicit roots require exact starts (its stack roots accept interiors).
 for(int i=0;i<COUNT;i++) roots[i]=(char*)roots[i]-1;
 interior_roots=false;
 hl_gc_major(); worker(verify); if(!verified || finalized!=1) return 5;
 for(int i=0;i<COUNT;i++) roots[i]=NULL;
 invalid_holder=NULL;
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=COUNT+1) return 6;
 for(int i=0;i<COUNT;i++) hl_remove_root(&roots[i]);
 hl_remove_root(&invalid_holder); hl_unregister_thread(); hl_global_free();
 puts("PASS: block lookup across size classes, interior roots and exact heap edges");
 return 0;
}
