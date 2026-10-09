/* Reuse an empty page after mark publication but before deferred reclamation. */
#include <hl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
HL_API void hl_gc_enable(bool);
HL_API void hl_gc_set_mark_threshold(double);
#define COUNT 512
static uintptr_t old[COUNT]; // Unregistered native memory is not a GC root.
static void **root, **fresh[16];
static int finalized, reused, fixed_reused, garbage_count=COUNT, fixed_count=65536;
static uintptr_t fixed_old[65536];
static void finish(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 for(int i=0;i<garbage_count;i++) old[i]=(uintptr_t)hl_gc_alloc_gen(NULL,65536,MEM_KIND_RAW|MEM_ZERO);
 for(int i=0;i<fixed_count;i++) fixed_old[i]=(uintptr_t)hl_gc_alloc_gen(NULL,40,MEM_KIND_RAW|MEM_ZERO);
 hl_unregister_thread(); return NULL;
}
static void *reuse(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 for(int i=0;i<16;i++) {
  fresh[i]=hl_gc_alloc_gen(NULL,40,MEM_KIND_RAW|MEM_ZERO);
  for(int j=0;j<fixed_count;j++) if((uintptr_t)fresh[i]==fixed_old[j]) fixed_reused=1;
  fresh[i][4]=(void*)(uintptr_t)123;
 }
 root=hl_gc_alloc_gen(NULL,65536,MEM_KIND_RAW|MEM_ZERO);
 for(int i=0;i<COUNT;i++) if((uintptr_t)root==old[i]) reused=1;
 void **target=hl_gc_alloc_gen(NULL,24,MEM_KIND_FINALIZER|MEM_ZERO);
 target[0]=(void*)finish; target[2]=(void*)(uintptr_t)42;
 hl_gc_store_ref(root,target,&hlt_dyn);
 root[8191]=(void*)(uintptr_t)123;
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t t; if(pthread_create(&t,NULL,fn,NULL)) hl_fatal("thread");
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
}
int main(int argc, char **argv) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 if(argc>1 && !strcmp(argv[1],"pressure")) { garbage_count=32; fixed_count=2048; hl_gc_set_mark_threshold(0.1); }
 hl_add_root(&root); for(int i=0;i<16;i++) hl_add_root(&fresh[i]); worker(setup);
 int steps=0;
 while(!hl_gc_incremental_reclaiming()) {
  if(hl_gc_step(0.001)) return 2;
  if(++steps>100000) return 3;
 }
 hl_gc_incremental_metrics m; hl_gc_incremental_stats(&m);
 if(!hl_gc_incremental_pending() || m.cycles_completed!=1) return 4;
 worker(reuse); if(!reused || !fixed_reused) return 5;
 // Fixed slots/TLAB reservations have no published mark bit; variable starts do.
 if(argc>1 && !strcmp(argv[1],"cancel")) {
  hl_gc_major(); if(hl_gc_incremental_pending() || hl_gc_incremental_reclaiming()) return 6;
 } else if(argc>1 && !strcmp(argv[1],"pressure")) {
  hl_gc_frame_begin(0); hl_gc_enable(true);
  for(int i=0;i<256;i++) hl_gc_alloc_gen(NULL,65536,MEM_KIND_NOPTR|MEM_ZERO);
  hl_gc_enable(false); hl_gc_frame_end(); hl_gc_incremental_stats(&m);
  if(!m.pressure_fallbacks || hl_gc_incremental_reclaiming()) return 14;
 } else {
  if(!hl_gc_frame_begin(0) || hl_gc_step(1000) || !hl_gc_incremental_reclaiming()) return 7;
  hl_gc_frame_end(); steps=0;
  while(!hl_gc_step(10)) if(++steps>100000) return 8;
  if(hl_gc_incremental_pending() || hl_gc_incremental_reclaiming() || !steps) return 9;
 }
 for(int i=0;i<16;i++) if(!hl_is_gc_ptr(fresh[i])) return 13;
 for(int i=0;i<16;i++) if(fresh[i][4]!=(void*)(uintptr_t)123) return 15;
 if(root[8191]!=(void*)(uintptr_t)123 || ((void**)root[0])[2]!=(void*)(uintptr_t)42 || finalized) return 10;
 hl_gc_major(); if(finalized || root[8191]!=(void*)(uintptr_t)123) return 11;
 root=NULL;
 for(int i=0;i<16;i++) { fresh[i]=NULL; hl_remove_root(&fresh[i]); }
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=1) return 12;
 hl_remove_root(&root); hl_unregister_thread(); hl_global_free();
 puts("PASS: allocation into a pending reclaim page, new finalizer and cancellation"); return 0;
}
