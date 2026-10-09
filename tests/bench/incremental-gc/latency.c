#include <hl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

HL_API void hl_gc_enable(bool);
typedef struct Node { struct Node *next; void *padding[3]; } Node;
typedef struct Finalizable { void (*finalize)(void*); char payload[120]; } Finalizable;
static Node *head;
static int nodes, finalized;
static double now(void) {
 struct timespec t;
 clock_gettime(CLOCK_MONOTONIC,&t);
 return t.tv_sec + t.tv_nsec * 1e-9;
}
static void finalize(void *value) { (void)value; finalized++; }
static void *setup(void *unused) {
 int marker = 0;
 (void)unused;
 hl_register_thread(&marker);
 for(int i = 0; i < nodes; i++) {
  Node *p = hl_gc_alloc_gen(NULL,sizeof(Node),MEM_KIND_RAW | MEM_ZERO);
  p->next = head;
  head = p;
 }
 hl_unregister_thread();
 return NULL;
}
int main(int argc, char **argv) {
 int marker = 0, incremental = argc > 1 && atoi(argv[1]);
 int frames = argc > 2 ? atoi(argv[2]) : 1200;
 nodes = argc > 3 ? atoi(argv[3]) : 500000;
 if(frames < 1 || nodes < 1) return 2;
 hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(incremental && !hl_gc_incremental_supported()) return 77;
 hl_add_root(&head);
 pthread_t worker;
 if(pthread_create(&worker,NULL,setup,NULL)) return 2;
 hl_blocking(true); pthread_join(worker,NULL); hl_blocking(false);
 hl_gc_major();
 puts("frame,frame_ms,allocation_ms,gc_ms,stepped,done,finalized");
 for(int frame = 0; frame < frames; frame++) {
  double start = now();
  /* Transient pointer-bearing allocations exercise lazy sweeping. Keep a few
   * reachable through old objects and mutate them between slices. */
  for(int i = 0; i < 256; i++) {
   void *p = hl_gc_alloc_gen(NULL,128,MEM_KIND_RAW | MEM_ZERO);
   if(i < 3) hl_gc_store_ref(&head->padding[i],p,&hlt_dyn);
  }
  for(int i = 0; i < 16; i++) {
   Finalizable *p = hl_gc_alloc_finalizer(sizeof(Finalizable));
   p->finalize = finalize;
  }
  double allocated = now();
  bool stepped = frame % 30 == 0 || (incremental && hl_gc_incremental_pending());
  bool done = false;
  if(stepped) {
   if(incremental) done = hl_gc_step(1000.0);
   else { hl_gc_major(); done = true; }
  }
  double end = now();
  printf("%d,%.6f,%.6f,%.6f,%d,%d,%d\n",frame,(end-start)*1000,
   (allocated-start)*1000,(end-allocated)*1000,stepped,done,finalized);
 }
 hl_remove_root(&head);
 hl_unregister_thread(); hl_global_free();
 return 0;
}
