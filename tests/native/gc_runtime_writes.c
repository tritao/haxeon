#include <hl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
HL_API void hl_gc_enable(bool);
extern void *realtime___iterator_new(vdynamic*);
extern vdynamic *realtime___iterator_next(void*);
extern void *realtime___string_buffer_new(void);
extern void realtime___string_buffer_add(void*,vstring*);
extern int realtime___string_buffer_length(void*);
static void *large, *iterator, *buffer;
static varray *hidden_array;
static void *hidden_target;
static int finalized, verified;
static void finalize(void *p) { (void)p; finalized++; }
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 large = hl_gc_alloc_gen(NULL,16 << 20,MEM_KIND_RAW | MEM_ZERO);
 hidden_array = hl_alloc_array(&hlt_dyn,1);
 void **target = hl_gc_alloc_gen(NULL,3 * sizeof(void*),MEM_KIND_FINALIZER | MEM_ZERO);
 target[0] = (void*)finalize; target[2] = (void*)123;
 hidden_target = target;
 hl_gc_store_ref(hl_aptr(hidden_array,void*),target,&hlt_dyn);
 buffer = realtime___string_buffer_new();
 hl_unregister_thread(); return NULL;
}
static void *mutate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 iterator = realtime___iterator_new((vdynamic*)hidden_array);
 uchar text[1000]; for(int i=0;i<1000;i++) text[i]='x';
 vstring value = {0}; value.bytes=text; value.length=1000;
 realtime___string_buffer_add(buffer,&value);
 hl_unregister_thread(); return NULL;
}
static void *verify(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 void *target = realtime___iterator_next(iterator);
 verified = target == hidden_target && ((void**)target)[2] == (void*)123 && realtime___string_buffer_length(buffer)==1000;
 hl_unregister_thread(); return NULL;
}
static void worker(void *(*fn)(void*)) {
 pthread_t thread; if(pthread_create(&thread,NULL,fn,NULL)) hl_fatal("worker");
 hl_blocking(true); pthread_join(thread,NULL); hl_blocking(false);
}
int main(void) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&large); hl_add_root(&iterator); hl_add_root(&buffer);
 worker(setup);
 if(hl_gc_step(0.001) || !hl_gc_incremental_pending()) return 2;
 worker(mutate);
 int slices=0; while(!hl_gc_step(1000.0)) if(++slices>10000) return 3;
 if(finalized) return 4;
 worker(verify); if(!verified) return 5;
 hidden_array=NULL; hidden_target=NULL; large=NULL; iterator=NULL; buffer=NULL;
 for(int i=0;i<4;i++) hl_gc_major();
 if(finalized!=1) return 6;
 hl_unregister_thread(); hl_global_free();
 puts("PASS: native runtime iterator capture, buffer growth and finalization"); return 0;
}
