#include <hl.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
HL_API void hl_gc_enable(bool);
static void *root;
static void *allocate(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 for(int i=0;i<32;i++) root=hl_gc_alloc_gen(NULL,32768,MEM_KIND_NOPTR|MEM_ZERO);
 hl_unregister_thread(); return NULL;
}
int main(int argc, char **argv) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 bool unsupported=argc>1 && !strcmp(argv[1],"unsupported");
 if(!hl_gc_incremental_supported() && !unsupported) return 77;
 hl_add_root(&root);
 hl_gc_frame_metrics m;
 if(!hl_gc_frame_begin(0) || hl_gc_frame_remaining()!=0) return 2;
 if(unsupported) {
  if(!hl_gc_step(1000)) return 3;
  hl_gc_frame_stats(&m); if(m.full_collections!=1 || m.explicit_slices!=1 || m.deferred_checks) return 4;
 } else if(argc>1 && !strcmp(argv[1],"pressure")) {
  hl_gc_enable(true);
  for(int i=0;i<1024;i++) root=hl_gc_alloc_gen(NULL,8192,MEM_KIND_NOPTR|MEM_ZERO);
  hl_gc_enable(false); hl_gc_frame_stats(&m);
  hl_gc_incremental_metrics inc; hl_gc_incremental_stats(&inc);
  if(!m.full_collections || !inc.pressure_fallbacks || m.automatic_slices || m.explicit_slices || !m.deferred_checks || hl_gc_frame_remaining()!=0) return 5;
 } else {
  if(hl_gc_step(1000) || hl_gc_incremental_pending()) return 6;
  if(hl_gc_frame_begin(NAN) || hl_gc_frame_begin(INFINITY) || hl_gc_frame_begin(-2) || hl_gc_frame_begin(100001) || hl_gc_frame_remaining()!=0) return 7;
  hl_gc_frame_stats(&m); if(m.deferred_checks!=1 || m.explicit_slices || m.spent_micros) return 8;
  if(!hl_gc_frame_begin(0.001) || hl_gc_step(1000)) return 9;
  hl_gc_frame_stats(&m); if(m.explicit_slices!=1 || m.spent_micros<0.001 || hl_gc_frame_remaining()!=0) return 10;
  if(hl_gc_step(1000)) return 11;
  hl_gc_enable(true);
  pthread_t t; if(pthread_create(&t,NULL,allocate,NULL)) return 12;
  hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
  hl_gc_enable(false); hl_gc_frame_stats(&m);
  if(m.explicit_slices!=1 || m.automatic_slices || m.deferred_checks<2 || m.full_collections) return 13;
  if(!hl_gc_frame_begin(1000)) return 14;
  int steps=0;
  while(hl_gc_frame_remaining()>0) { hl_gc_step(1000); if(++steps>10000) return 15; }
  hl_gc_frame_stats(&m); if(!m.explicit_slices || m.deferred_checks || m.spent_micros<1000) return 16;
  if(!hl_gc_frame_begin(-1) || hl_gc_frame_remaining()!=-1) return 17;
  steps=0; while(!hl_gc_step(1000)) if(++steps>10000) return 18;
  hl_gc_frame_stats(&m); if(!m.explicit_slices || m.deferred_checks) return 19;
 }
 hl_gc_frame_end(); if(hl_gc_frame_remaining()!=-1) return 20;
 root=NULL; hl_remove_root(&root); hl_gc_major(); hl_unregister_thread(); hl_global_free();
 puts("PASS: shared frame budget, renewal, deferral and mandatory collection"); return 0;
}
