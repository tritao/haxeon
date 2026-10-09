#include <hl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
HL_API void hl_gc_enable(bool);
HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);
typedef struct Node { struct Node *next; void *ref; unsigned long long tag; void *pad[5]; } Node;
static Node *head;
static Node **holders, **graphs;
static void **boundary_holder;
static int nodes, scale;
static bool scan_profile;
static int boundary_requested, boundary_actual, boundary_volume;
static unsigned long long profile_collections;
static double now(void) {
 struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
 return t.tv_sec+t.tv_nsec*1e-9;
}
static Node *node(Node *next) {
 Node *p=hl_gc_alloc_gen(NULL,sizeof(Node),MEM_KIND_RAW|MEM_ZERO);
 p->tag=42; hl_gc_store_ref(&p->next,next,&hlt_dyn); return p;
}
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 // A distinct size class keeps the publication slot off stable Node pages.
 if(boundary_requested) boundary_holder=hl_gc_alloc_gen(NULL,sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 holders=hl_gc_alloc_gen(NULL,4096*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 graphs=hl_gc_alloc_gen(NULL,8*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 for(int i=0;i<nodes;i++) head=node(head);
 for(int i=0;i<4096;i++) holders[i]=node(NULL);
 hl_unregister_thread(); return NULL;
}
static void rewrite(int frame) {
 for(int i=0;i<256*scale;i++) {
  Node *value=node(NULL);
  for(int j=0;j<16;j++) hl_gc_store_ref(&holders[(frame*257+i*16+j)&4095]->ref,value,&hlt_dyn);
 }
}
static void replace_array(int frame,int slots) {
 void **array=hl_gc_alloc_gen(NULL,slots*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 // This bulk initialization has no allocating conversion or safepoint.
 for(int i=0;i<slots;i++) array[i]=holders[(i+frame)&4095];
 hl_gc_record_write(array,slots*sizeof(void*));
 hl_gc_store_ref(&holders[0]->ref,array,&hlt_dyn);
}
static void replace_boundary(int frame,bool pointers,bool zeros) {
 uintptr_t *payload=hl_gc_alloc_gen(NULL,boundary_requested,(pointers?MEM_KIND_RAW:MEM_KIND_NOPTR)|MEM_ZERO);
 boundary_actual=hl_gc_get_memsize(payload);
 if(boundary_actual<boundary_requested || boundary_volume-boundary_actual<(1<<20)) hl_fatal("invalid boundary allocation sizes");
 int words=boundary_actual/sizeof(uintptr_t);
 // refs and bytes write identical address bits and touch the entire rounded
 // payload. MEM_KIND_NOPTR makes those bits data, not managed references.
 for(int i=0;i<words;i++) payload[i]=zeros?0:(uintptr_t)holders[(i+frame)&4095];
 hl_gc_record_write(payload,boundary_actual);
 hl_gc_store_ref(boundary_holder,payload,&hlt_dyn);
 if(scan_profile) fprintf(stderr,"GC-SCAN-PUBLISH,frame=%d,block=%p,bytes=%d\n",frame,(void*)payload,boundary_actual);
 int filler_bytes=boundary_volume-boundary_actual;
 uintptr_t *filler=hl_gc_alloc_gen(NULL,filler_bytes,MEM_KIND_NOPTR|MEM_ZERO);
 for(int i=0;i<filler_bytes/(int)sizeof(uintptr_t);i++) filler[i]=(uintptr_t)holders[(i+frame)&4095];
 hl_gc_record_write(filler,filler_bytes);
}

static void allocate_graph(int frame,int count) {
 Node *graph=NULL;
 for(int i=0;i<count;i++) graph=node(graph);
 hl_gc_store_ref(&graphs[frame&7],graph,&hlt_dyn);
}
static unsigned long long heap(unsigned long long *allocated) {
 unsigned long long allocations,bytes,collections,mark;
 hl_gc_profile_stats(allocated,&allocations,&bytes,&collections,&mark); profile_collections=collections; return bytes;
}
int main(int argc,char **argv) {
 if(argc!=7 && argc!=9) return 2;
 const char *workload=argv[1]; int frames=atoi(argv[2]); nodes=atoi(argv[3]);
 scale=atoi(argv[4]); double budget=atof(argv[5]); int automatic_mode=atoi(argv[6]); bool automatic=automatic_mode!=0;
 if(frames<1 || nodes<1 || scale<1 || scale>16 || !(budget>0) || budget>100000) return 2;
 bool boundary=!strncmp(workload,"boundary-",9);
 if(boundary) {
  if(argc!=9 || (strcmp(workload,"boundary-refs") && strcmp(workload,"boundary-bytes") && strcmp(workload,"boundary-zeros"))) return 2;
  boundary_requested=atoi(argv[7]); boundary_volume=atoi(argv[8]);
  if(boundary_requested<(1<<20)-65536 || boundary_requested>(1<<20)+65536 || boundary_volume<(4<<20) || boundary_volume>(64<<20) || boundary_volume%65536) return 2;
 } else if(argc!=7) return 2;
 if(!boundary && strcmp(workload,"rewrite") && strcmp(workload,"arrays") && strcmp(workload,"graphs") && strcmp(workload,"overload")) return 2;
 scan_profile=(getenv("HL_GC_SCAN_PROFILE") && !strcmp(getenv("HL_GC_SCAN_PROFILE"),"1")) || (getenv("HL_GC_RETENTION_PROFILE") && !strcmp(getenv("HL_GC_RETENTION_PROFILE"),"1"));
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&head); hl_add_root(&holders); hl_add_root(&graphs);
 if(boundary) hl_add_root(&boundary_holder);
 pthread_t t; if(pthread_create(&t,NULL,setup,NULL)) return 3;
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
 hl_gc_major();
 unsigned long long allocated,baseline=heap(&allocated),baseline_collections=profile_collections;
 hl_gc_enable(automatic);
 unsigned long long previous_allocated=allocated;
 const char *frame_setting=getenv("GC_STRESS_FRAME_BUDGET_US");
 double frame_budget=frame_setting?atof(frame_setting):-1;
 puts("frame,frame_ms,allocation_ms,gc_ms,heap_bytes,allocated_bytes,pending,cycles_started,cycles_completed,pressure_fallbacks,tracking_fallbacks,full_collections,dirty_pages,mark_objects,cycle_age_ms,last_cycle_ms,frame_gc_us,frame_auto_slices,frame_explicit_slices,frame_deferred,frame_full");
 for(int frame=0;frame<frames;frame++) {
  double start=now();
  if(frame_setting && !hl_gc_frame_begin(frame_budget)) return 8;
  if(boundary) replace_boundary(frame,strcmp(workload,"boundary-bytes")!=0,!strcmp(workload,"boundary-zeros"));
  if(!strcmp(workload,"rewrite") || !strcmp(workload,"overload")) rewrite(frame);
  if(!strcmp(workload,"arrays")) replace_array(frame,131072*scale);
  if(!strcmp(workload,"graphs")) allocate_graph(frame,4096*scale);
  if(!strcmp(workload,"overload")) { replace_array(frame,524288*scale); allocate_graph(frame,8192*scale); }
  double allocated_at=now();
  if(automatic_mode!=2) hl_gc_step(budget); // Mode 2 measures allocation-driven pacing alone.
  double end=now();
  hl_gc_frame_metrics fm={0};
  if(frame_setting) { hl_gc_frame_stats(&fm); hl_gc_frame_end(); }
  hl_gc_incremental_metrics m; hl_gc_incremental_stats(&m);
  unsigned long long bytes=heap(&allocated);
  if(boundary && allocated-previous_allocated!=(unsigned long long)boundary_volume) return 6;
  previous_allocated=allocated;
  printf("%d,%.6f,%.6f,%.6f,%llu,%llu,%d,%llu,%llu,%llu,%llu,%llu,%u,%u,%.6f,%.6f,%.6f,%llu,%llu,%llu,%llu\n",
   frame,(end-start)*1000,(allocated_at-start)*1000,(end-allocated_at)*1000,bytes,allocated,
   hl_gc_incremental_pending(),m.cycles_started,m.cycles_completed,m.pressure_fallbacks,m.tracking_fallbacks,
   profile_collections-baseline_collections-m.cycles_completed,m.dirty_pages,m.mark_objects,m.cycle_age_micros/1000,m.last_cycle_micros/1000,fm.spent_micros,fm.automatic_slices,fm.explicit_slices,fm.deferred_checks,fm.full_collections);
 }
 // Stop mutation and finish the existing cycle; report this separately so
 // eventual quiescent completion cannot be mistaken for convergence under load.
 hl_gc_enable(false);
 if(scan_profile) fprintf(stderr,"GC-SCAN-DRAIN\n");
 if(getenv("HL_GC_LATENCY_TRACE") && !strcmp(getenv("HL_GC_LATENCY_TRACE"),"1")) fprintf(stderr,"GC-LATENCY-DRAIN\n");
 int drain=0; double drain_start=now();
 while(hl_gc_incremental_pending()) { hl_gc_step(budget); if(++drain>10000) return 4; }
 double drain_ms=(now()-drain_start)*1000;
 unsigned long long drained=heap(&allocated);
 hl_gc_major(); unsigned long long after_major=heap(&allocated);
 // The retained old graph, array contents and newest graph must remain valid.
 if(head->tag!=42) return 5;
 for(int i=0;i<4096;i++) if(holders[i]->tag!=42) return 5;
 for(int i=0;i<8;i++) for(Node *p=graphs[i];p;p=p->next) if(p->tag!=42) return 5;
 if(!strcmp(workload,"arrays") || !strcmp(workload,"overload")) {
  void **array=holders[0]->ref; int slots=(!strcmp(workload,"arrays")?131072:524288)*scale;
  if(((Node*)array[0])->tag!=42 || ((Node*)array[slots-1])->tag!=42) return 5;
 }
 if(boundary) {
  uintptr_t *payload=boundary_holder[0];
  int last=boundary_actual/(int)sizeof(uintptr_t)-1;
  bool zeros=!strcmp(workload,"boundary-zeros");
  if(payload[0]!=(zeros?0:(uintptr_t)holders[(frames-1)&4095]) || payload[last]!=(zeros?0:(uintptr_t)holders[(last+frames-1)&4095])) return 7;
 }
 fprintf(stderr,"STRESS-END,baseline_heap=%llu,heap_after_drain=%llu,heap_after_major=%llu,drain_steps=%d,drain_ms=%.6f,primary_requested=%d,primary_allocated=%d,frame_allocated=%d\n",
  baseline,drained,after_major,drain,drain_ms,boundary_requested,boundary_actual,boundary_volume);
 hl_remove_root(&head); hl_remove_root(&holders); hl_remove_root(&graphs);
 if(boundary) hl_remove_root(&boundary_holder);
 hl_unregister_thread(); hl_global_free(); return 0;
}
