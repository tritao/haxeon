/* Retention metadata must not keep black garbage alive in the next cycle. */
#include <hl.h>
#include <pthread.h>
#include <stdio.h>
HL_API void hl_gc_enable(bool);
static void *live;
static int finalized;
static void finish(void *p) { (void)p; finalized++; }
static void *allocate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 void **dead=hl_gc_alloc_gen(NULL,32,MEM_KIND_FINALIZER|MEM_ZERO);
 dead[0]=(void*)finish;
 live=hl_gc_alloc_gen(NULL,1048576,MEM_KIND_NOPTR|MEM_ZERO);
 hl_unregister_thread(); return NULL;
}
int main(void) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&live);
 if(hl_gc_step(0.001)) return 2;
 pthread_t t; if(pthread_create(&t,NULL,allocate,NULL)) return 3;
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
 int steps=0; while(!hl_gc_step(100)) if(++steps>100000) return 4;
 if(finalized) return 5;
 live=NULL;
 for(int i=0;i<6;i++) hl_gc_major();
 if(finalized!=1) return 6;
 hl_remove_root(&live); hl_unregister_thread(); hl_global_free();
 puts("PASS: black retention and later reclamation"); return 0;
}
