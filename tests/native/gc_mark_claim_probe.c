#define HL_NAME(n) gcclaim_##n
/* Tests the actual private bitmap helper exported only by the scratch test library. */
#include <hl.h>
#include <pthread.h>
HL_API bool hl_gc_mark_claim_test(unsigned char *,unsigned char);
HL_API int hl_gc_get_mark_threads(hl_thread **);
static pthread_barrier_t start,done;
static unsigned char bits;
static int winners;
static void *worker(void *arg) {
 int id=(int)(intptr_t)arg;
 for(int round=0;round<2000;round++) {
  pthread_barrier_wait(&start);
  unsigned char mask=1<<(id%((round&1)?4:8));
  if(hl_gc_mark_claim_test(&bits,mask)) __atomic_fetch_add(&winners,1,__ATOMIC_RELAXED);
  pthread_barrier_wait(&done);
 }
 return NULL;
}
HL_PRIM int HL_NAME(run)(void) {
 if(hl_gc_get_mark_threads(NULL)==0) {
  for(int round=0;round<10000;round++) {
   unsigned char bitmap=0;
   for(int bit=0;bit<8;bit++) {
    unsigned char mask=1<<bit;
    if(!hl_gc_mark_claim_test(&bitmap,mask) || hl_gc_mark_claim_test(&bitmap,mask)) return 1;
   }
   if(bitmap!=255) return 2;
  }
  return 0;
 }
 pthread_t threads[8];int failures=0;
 pthread_barrier_init(&start,NULL,9);pthread_barrier_init(&done,NULL,9);
 for(int i=0;i<8;i++) if(pthread_create(&threads[i],NULL,worker,(void*)(intptr_t)i)) abort();
 for(int round=0;round<2000;round++) {
  bits=0;winners=0;
  pthread_barrier_wait(&start);pthread_barrier_wait(&done);
  if(bits!=((round&1)?15:255) || winners!=((round&1)?4:8)) failures++;
 }
 for(int i=0;i<8;i++) pthread_join(threads[i],NULL);
 pthread_barrier_destroy(&start);pthread_barrier_destroy(&done);
 return failures;
}
DEFINE_PRIM(_I32,run,_NO_ARG);
