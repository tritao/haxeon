/* An unbarriered write behind a suspended captured-array field cursor must
 * survive the next kernel capture, even though the previous batch was frozen. */
#include <hl.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
HL_API void hl_gc_enable(bool);
static void **source;
static void *hidden;
static int finalized, verified;
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 source=hl_gc_alloc_gen(NULL,1<<20,MEM_KIND_RAW|MEM_ZERO);
 void **target=hl_gc_alloc_gen(NULL,3*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
 target[0]=(void*)finalize; target[2]=(void*)42; hidden=target;
 hl_unregister_thread(); return NULL;
}
static void *dirty(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 *(void *volatile *)source=NULL;
 hl_gc_record_write(source,sizeof(void*));
 hl_unregister_thread(); return NULL;
}
static void *mutate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 source[0]=hidden; // Deliberately bypass the software barrier.
 hl_unregister_thread(); return NULL;
}
static void *verify(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 void **target=source[0]; verified=target==hidden && target[2]==(void*)42;
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t t; if(pthread_create(&t,NULL,fn,NULL)) hl_fatal("worker");
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
}
int main(void) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 void (*watch)(void*)=dlsym(RTLD_DEFAULT,"gc_test_watch_dirty");
 int (*seen)(void)=dlsym(RTLD_DEFAULT,"gc_test_dirty_seen");
 if(!watch || !seen) return 2;
 hl_add_root(&source); worker(setup);
 if(hl_gc_step(0.001)) return 3;
 int steps=0;
 while(hl_gc_incremental_preparing()) if(hl_gc_step(0.001) || ++steps>100000) return 4;
 worker(dirty); watch(source);
 // The initial white-array scan must drain before capture. Once capture has
 // been observed, a new mark-stack entry can only be its captured-page rescan.
 while(!seen()) if(hl_gc_step(0.001) || ++steps>100000) return 5;
 hl_gc_incremental_metrics m; hl_gc_incremental_stats(&m);
 while(!m.mark_objects) {
  if(hl_gc_step(0.001) || ++steps>100000) return 6;
  hl_gc_incremental_stats(&m);
 }
 if(m.mark_objects!=1 || hl_gc_incremental_rescanning()) return 7;
 // Drain at least the first 256 fields; the 1 MiB object cannot finish in a
 // 1 ns allowance. The next mutation is behind this suspended field cursor.
 if(hl_gc_step(0.001) || !hl_gc_incremental_pending()) return 8;
 worker(mutate);
 if(getenv("HL_GC_TEST_CANCEL_DIRTY")) {
  hl_gc_major();
  if(hl_gc_incremental_pending() || finalized) return 9;
 }
 steps=0; while(!hl_gc_step(1000)) if(++steps>100000) return 10;
 if(finalized) return 11;
 worker(verify); if(!verified) return 12;
 source=NULL; hidden=NULL;
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=1) return 13;
 hl_remove_root(&source); hl_unregister_thread(); hl_global_free();
 puts("PASS: unbarriered write behind suspended captured-array field cursor");
 return 0;
}
