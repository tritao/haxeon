/* Earlier starts must apply to automatic allocation checks, not full-GC limits. */
#include <hl.h>
#include <stdio.h>
#include <stdlib.h>
HL_API void hl_gc_enable(bool);
HL_API void hl_gc_profile_stats(unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*,unsigned long long*);
static void *roots[40];
int main(int argc, char **argv) {
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported() && argc!=3) return 77;
 for(int i=0;i<40;i++) hl_add_root(&roots[i]);
 hl_gc_major();
 unsigned long long a,b,h,baseline,elapsed,collections;
 hl_gc_profile_stats(&a,&b,&h,&baseline,&elapsed);
 hl_gc_enable(true);
 for(int i=0;i<40;i++) roots[i]=hl_gc_alloc_gen(NULL,1<<20,MEM_KIND_NOPTR|MEM_ZERO);
 hl_gc_incremental_metrics m; hl_gc_incremental_stats(&m);
 hl_gc_profile_stats(&a,&b,&h,&collections,&elapsed);
 if(argc<2 || (!!m.cycles_started != !!atoi(argv[1])) || m.pressure_fallbacks || m.tracking_fallbacks) return 2;
 if(!atoi(argv[1]) && collections!=baseline) return 3;
 hl_gc_enable(false);
 while(hl_gc_incremental_pending()) hl_gc_step(1000);
 for(int i=0;i<40;i++) { roots[i]=NULL; hl_remove_root(&roots[i]); }
 hl_gc_major(); hl_unregister_thread(); hl_global_free();
 puts("PASS: automatic incremental start threshold"); return 0;
}
