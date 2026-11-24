/* Isolate first field traversal per cycle without allocation/mutation pressure.
 * The convergence benchmark remains the end-to-end latency/retention check. */
#include <hl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
HL_API void hl_gc_enable(bool);
typedef struct { uintptr_t tag; void *pad[7]; } Target;
static void **source;
static Target **targets;
static size_t bytes;
static const char *mode;
static double cpu_now(void) {
 struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t);
 return t.tv_sec+t.tv_nsec*1e-9;
}
static double now(void) {
 struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
 return t.tv_sec+t.tv_nsec*1e-9;
}
static void *setup(void *unused) {
 int marker; (void)unused; hl_register_thread(&marker);
 targets=hl_gc_alloc_gen(NULL,4096*sizeof(void*),MEM_KIND_RAW|MEM_ZERO);
 for(int i=0;i<4096;i++) {
  targets[i]=hl_gc_alloc_gen(NULL,sizeof(Target),MEM_KIND_RAW|MEM_ZERO);
  targets[i]->tag=42;
 }
 source=hl_gc_alloc_gen(NULL,(int)bytes,MEM_KIND_RAW|MEM_ZERO);
 for(size_t i=0;i<bytes/sizeof(void*);i++) {
  if(!strcmp(mode,"local")) source[i]=targets[i&4095];
  else if(!strcmp(mode,"scattered")) source[i]=targets[(i*1031)&4095];
  else if(!strcmp(mode,"interior")) source[i]=(char*)targets[i&4095]+sizeof(void*);
  else if(!strcmp(mode,"invalid")) source[i]=(void*)(uintptr_t)(0x12345001+(i&4095)*16);
 }
 hl_unregister_thread(); return NULL;
}
int main(int argc,char **argv) {
 if(argc!=4) return 2;
 mode=argv[1]; int mib=atoi(argv[2]),cycles=atoi(argv[3]);
 if(mib<1 || mib>512 || cycles<1 || cycles>1000) return 2;
 if(strcmp(mode,"local") && strcmp(mode,"scattered") && strcmp(mode,"interior") && strcmp(mode,"invalid") && strcmp(mode,"null")) return 2;
 bytes=(size_t)mib<<20;
 int marker; hl_global_init(); hl_register_thread(&marker); hl_gc_enable(false);
 if(!hl_gc_incremental_supported()) return 77;
 hl_add_root(&source); hl_add_root(&targets);
 pthread_t t; if(pthread_create(&t,NULL,setup,NULL)) return 3;
 hl_blocking(true); pthread_join(t,NULL); hl_blocking(false);
 hl_gc_major();
 puts("cycle,bytes,elapsed_ms,cpu_ms,steps");
 for(int i=0;i<cycles;i++) {
  int steps=0; double start=now(),cpu_start=cpu_now(); bool done;
  do { done=hl_gc_step(1000); if(++steps>100000) return 4; } while(!done);
  double cpu=(cpu_now()-cpu_start)*1000,elapsed=(now()-start)*1000;
  for(int j=0;j<4096;j++) if(targets[j]->tag!=42) return 5;
  printf("%d,%zu,%.6f,%.6f,%d\n",i,bytes,elapsed,cpu,steps);
 }
 hl_remove_root(&source); hl_remove_root(&targets);
 hl_unregister_thread(); hl_global_free(); return 0;
}
