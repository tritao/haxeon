#include <hl.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
HL_API void hl_gc_enable(bool);
static void *ballast, *hidden;
static void **sources;
static int finalized, verified;
static bool software;
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 ballast=hl_gc_alloc_gen(NULL,16<<20,MEM_KIND_RAW|MEM_ZERO);
 sources=hl_gc_alloc_gen(NULL,256*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 for(int i=0;i<256;i++) sources[i]=hl_gc_alloc_gen(NULL,128,MEM_KIND_RAW|MEM_ZERO);
 void **target=hl_gc_alloc_gen(NULL,3*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
 target[0]=(void*)finalize; target[2]=(void*)42; hidden=target;
 hl_unregister_thread(); return NULL;
}
static void *dirty(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 hl_gc_record_write(sources[0],128);
 hl_unregister_thread(); return NULL;
}
static void *mutate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 if(software && !getenv("HL_GC_TEST_UNBARRIERED_REDIRTY")) hl_gc_store_ref(sources[0],hidden,&hlt_dyn);
 else *(void**)sources[0]=hidden; /* Deliberately bypass the software barrier. */
 hl_unregister_thread(); return NULL;
}
static void *verify(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 void **target=*(void***)sources[0];
 verified=target==hidden && target[2]==(void*)42;
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t t; if(pthread_create(&t,NULL,fn,NULL)) hl_fatal("worker");
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
}
int main(int argc,char **argv) {
 (void)argv; software=argc>1;
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&ballast); hl_add_root(&sources); worker(setup);
 if(hl_gc_step(0.001) || !hl_gc_incremental_preparing()) return 2;
 if(software) {
  int steps=0;
  while(hl_gc_incremental_preparing()) if(hl_gc_step(0.001) || ++steps>100000) return 3;
  // Trace the small source graph before pausing within the large ballast.
  if(hl_gc_step(100) || !hl_gc_incremental_pending()) return 4;
  worker(dirty);
  // Incoming writes wait until the current trace and kernel capture finish.
  steps=0;
  while(!hl_gc_incremental_rescanning())
   if(hl_gc_step(0.001) || ++steps>100000) return 5;
  // Re-dirty the page while its earlier scan is suspended. The old prefix
  // must be revisited after the in-progress scan finishes.
  worker(mutate);
 } else {
  void (*watch)(void*)=dlsym(RTLD_DEFAULT,"gc_test_watch_dirty");
  int (*seen)(void)=dlsym(RTLD_DEFAULT,"gc_test_dirty_seen");
  if(!watch || !seen) return 6;
  watch(sources[0]);
  int steps=0;
  while(!seen()) if(hl_gc_step(0.001) || ++steps>100000) return 7;
  // Tiny slices stop immediately after a capture chunk. Mutate a page that
  // has already been visited, before the process-wide clear_refs rearm.
  worker(mutate);
 }
 if(getenv("HL_GC_TEST_CANCEL_DIRTY")) {
  hl_gc_major();
  if(hl_gc_incremental_pending() || hl_gc_incremental_preparing() || hl_gc_incremental_rescanning() || finalized) return 12;
  if(hl_gc_step(0.001) || !hl_gc_incremental_pending()) return 13;
 }
 int steps=0; while(!hl_gc_step(1000)) if(++steps>100000) return 8;
 if(finalized) return 9;
 worker(verify); if(!verified) return 10;
 ballast=NULL; sources=NULL; hidden=NULL;
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=1) return 11;
 hl_unregister_thread(); hl_global_free();
 puts(software ? "PASS: mutation during suspended captured-page rescan" : "PASS: unbarriered write after partial kernel capture");
 return 0;
}
