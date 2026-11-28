/* A cycle must end however short its slices: here each is shorter than any phase, and the mutator re-dirties the
 * list's newest page between them, so marking never reaches a fixed point; the work bound ends it in a full collection. */
#include <hl.h>
#include <stdio.h>
HL_API void hl_gc_enable(bool);
static void **head;
static void **cell(void *next) {
 void **made=hl_gc_alloc_gen(NULL,2*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 hl_gc_store_ref(&made[0],next,NULL);
 return made;
}
int main(void) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&head);
 for(int i=0;i<100000;i++) head=cell(head);
 hl_gc_incremental_metrics before; hl_gc_incremental_stats(&before);
 if(hl_gc_step(0.01) || !hl_gc_incremental_pending()) return 2;
 bool done=false;
 for(int slice=0;slice<10000000 && !done;slice++) {
  for(int i=0;i<32;i++) head=cell(head);
  done=hl_gc_step(0.01);
 }
 if(!done) return 3;
 hl_gc_incremental_metrics after; hl_gc_incremental_stats(&after);
 if(after.work_fallbacks!=before.work_fallbacks+1 || after.pressure_fallbacks!=before.pressure_fallbacks) return 4;
 int count=0;
 for(void **at=head;at;at=at[0]) count++;
 if(count<=100000) return 5;
 while(hl_gc_incremental_pending() || hl_gc_incremental_reclaiming()) hl_gc_step(1000);
 hl_remove_root(&head); hl_gc_major(); hl_unregister_thread(); hl_global_free();
 puts("PASS: an incremental cycle whose slices cannot reach a fixed point ends in a full collection");
 return 0;
}
