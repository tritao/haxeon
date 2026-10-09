#include <hl.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
HL_API void hl_gc_enable(bool);
extern void *realtime___bytes_alloc(int);
extern void *realtime___bytes_view(void*,int,int);
extern void *realtime_structWithRoots(void*,varray*);
extern varray *realtime_structGetRoots(void*);
extern void realtime___bytes_set(void*,int,int);
extern int realtime___bytes_get(void*,int);
static void *large, *structure, *view, *hidden;
static int finalized, verified;
static bool use_closure;
static hl_type closure_type = { HFUN };
static hl_type_fun closure_layout;
static hl_type *closure_args[] = { &hlt_bytes };
static void capture_stub(void *value) { (void)value; }
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 large=hl_gc_alloc_gen(NULL,16<<20,MEM_KIND_RAW|MEM_ZERO);
 void **target=hl_gc_alloc_gen(NULL,3*sizeof(void*),MEM_KIND_FINALIZER|MEM_ZERO);
 target[0]=(void*)finalize; target[2]=(void*)42;
 hidden=use_closure ? (void*)hl_alloc_closure_ptr(&closure_type,capture_stub,target) : (void*)target;
 void *owner=realtime___bytes_alloc(8);
 realtime___bytes_set(owner,2,42);
 view=realtime___bytes_view(owner,2,4);
 structure=realtime_structWithRoots(owner,hl_alloc_array(&hlt_dyn,1));
 hl_unregister_thread(); return NULL;
}
static void *mutate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 varray *roots=realtime_structGetRoots(structure);
 void (*drop)(void*,size_t)=dlsym(RTLD_DEFAULT,"gc_test_drop_range");
 if(drop) drop(hl_aptr(roots,void*),sizeof(void*));
 hl_gc_store_ref(hl_aptr(roots,void*),hidden,&hlt_dyn);
 hl_unregister_thread(); return NULL;
}
static void *verify(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 varray *roots=realtime_structGetRoots(structure);
 void *stored=hl_aptr(roots,void*)[0];
 void **target=use_closure ? (void**)((vclosure*)stored)->value : (void**)stored;
 verified=stored==hidden && target[2]==(void*)42 && realtime___bytes_get(view,0)==42;
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t thread; if(pthread_create(&thread,NULL,fn,NULL)) hl_fatal("worker");
 hl_blocking(true); pthread_join(thread,NULL); hl_blocking(false);
}
int main(int argc, char **argv) {
 (void)argv; use_closure=argc>1;
 closure_layout.args=closure_args; closure_layout.nargs=1; closure_layout.ret=&hlt_void;
 closure_type.fun=&closure_layout;
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 hl_add_root(&large); hl_add_root(&structure); hl_add_root(&view);
 worker(setup);
 if(hl_gc_step(0.001) || !hl_gc_incremental_pending()) return 2;
 if(!hl_gc_incremental_preparing()) return 7;
 if(getenv("HL_GC_TEST_AFTER_PREPARATION")) {
  int prepared=0;
  while(hl_gc_incremental_preparing()) {
   if(hl_gc_step(0.001) || ++prepared>100000) return 8;
  }
  // Scan the small root graph before modifying its old array; the large
  // pointer-bearing ballast keeps marking pending.
  if(hl_gc_step(100) || !hl_gc_incremental_pending()) return 9;
 }
 worker(mutate);
 int slices=0; while(!hl_gc_step(1000)) if(++slices>10000) return 3;
 if(finalized) return 4;
 worker(verify); if(!verified) return 5;
 hidden=NULL; large=NULL; structure=NULL; view=NULL;
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=1) return 6;
 hl_unregister_thread(); hl_global_free();
 puts("PASS: FFI managed root-array mutation, borrowed Bytes view, finalization"); return 0;
}
