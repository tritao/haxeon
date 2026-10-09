/* Host-side backend contract test. Does not exercise the Apple ABI or JIT. */
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <pthread.h>
#undef __linux__
#define __APPLE__ 1
#define __aarch64__ 1
#define HL_GC_APPLE_SOFTWARE_TEST 1
#define HL_API
#define GC_MASK_BITS 16
#define GC_LEVEL1_MASK 15
#define GC_ALL_PAGES 1
#define MEM_HAS_PTR(kind) (kind)
typedef struct gc_pheader {
 uintptr_t base;
 size_t page_size;
 int page_kind, software_dirty;
 unsigned int scan_dirty_sources;
 struct gc_pheader *next_page, *software_dirty_next;
} gc_pheader;
static bool gc_scan_profile_enabled = true;
static gc_pheader *gc_pages[1], *page_map[16];
static gc_pheader **level1 = page_map;
#define GC_GET_LEVEL1(ptr) level1
#define gc_hash(ptr) ((uintptr_t)(ptr))
#define INPAGE(ptr,p) ((uintptr_t)(ptr) >= (p)->base && (uintptr_t)(ptr) - (p)->base < (p)->page_size)
#define hl_fatal(message) do { fprintf(stderr,"%s\n",message); exit(1); } while(0)
#include "../../vendor/hashlink/src/gc_write_tracking.c"
static int visits;
static void visit(gc_pheader *p) { assert(p->page_kind); visits++; }
static void *writer(void *unused) {
 (void)unused;
 for(int i=0;i<1000;i++) hl_gc_write_barrier((void*)0x1fff8,65552);
 return NULL;
}
int main(void) {
 gc_pheader a = {0x10000,65536,1,0,0,NULL,NULL};
 gc_pheader b = {0x20000,65536,1,0,0,NULL,NULL};
 gc_pheader scalar = {0x30000,65536,0,0,0,NULL,NULL};
 a.next_page = &b; b.next_page = &scalar; gc_pages[0] = &a;
 page_map[1] = &a; page_map[2] = &b; page_map[3] = &scalar;
 unsetenv("HL_GC_INCREMENTAL_TEST_SOFTWARE");
 gc_inc_tracking_configure(); assert(!gc_write_tracking.supported());
 setenv("HL_GC_INCREMENTAL_TEST_SOFTWARE","1",1);
 setenv("HL_GC_INCREMENTAL_VALIDATE","1",1);
 gc_inc_tracking_configure(); assert(gc_write_tracking.supported());
 assert(gc_write_tracking.begin()); assert(hl_gc_write_barrier_active);
 hl_gc_write_barrier((void*)0x1fff8,65552);
 assert(a.software_dirty && b.software_dirty && !scalar.software_dirty);
 bool complete;
 assert(gc_write_tracking.collect(0,&complete) && complete);
 assert(!gc_dirty_pop()); // Incoming notifications wait for capture.
 gc_dirty_capture_done();
 gc_pheader *page; while((page=gc_dirty_pop())) visit(page);
 assert(visits == 2);
 assert(gc_dirty_sources(&a)==1 && gc_dirty_sources(&b)==1);
 gc_dirty_enqueue_source(&a,2); gc_dirty_enqueue(&a);
 gc_dirty_capture_done();
 assert(gc_dirty_pop()==&a && gc_dirty_sources(&a)==3);
 assert(gc_write_tracking.collect(0,&complete) && complete);
 assert(!gc_dirty_pop() && visits == 2);
 // Clear/pop before resuming writers: an in-flight rescan does not own the
 // intrusive link, so the same page may be queued again independently.
 hl_gc_write_barrier((void*)0x10000,8);
 gc_dirty_capture_done();
 gc_pheader *inflight=gc_dirty_pop(); assert(inflight==&a);
 hl_gc_write_barrier((void*)0x10000,8);
 assert(!gc_dirty_pop() && gc_software_dirty_count==1);
 gc_dirty_capture_done();
 assert(gc_dirty_pop()==inflight && !gc_dirty_pop());
 for(int repeat=0;repeat<10;repeat++) {
  pthread_t writers[4];
  for(int i=0;i<4;i++) assert(!pthread_create(&writers[i],NULL,writer,NULL));
  for(int i=0;i<4;i++) assert(!pthread_join(writers[i],NULL));
  gc_dirty_capture_done();
  // Writes to a page still pending in this batch do not create a second node.
  writer(NULL);
  assert(gc_software_dirty_count==2);
  int count=0;
  while((page=gc_dirty_pop())) { assert(page==&a || page==&b); assert(++count<=2); }
  assert(count==2 && !a.software_dirty && !b.software_dirty && gc_software_dirty_count==0);
 }

 hl_gc_write_barrier((void*)0x10000,8);
 gc_dirty_capture_done();
 hl_gc_write_barrier((void*)0x20000,8);
 assert(gc_software_dirty_count==2 && gc_dirty_pop()==&a && !gc_dirty_pop());
 assert(gc_software_dirty_count==1);
 gc_dirty_capture_done(); assert(gc_dirty_pop()==&b && !gc_dirty_pop());
 hl_gc_write_barrier((void*)0x10000,8); gc_dirty_capture_done();
 hl_gc_write_barrier((void*)0x20000,8);
 assert(gc_write_tracking.rearm()); assert(!gc_write_tracking.isolated_mappings());
 gc_write_tracking.end(); hl_gc_write_barrier((void*)0x10000,8);
 assert(!hl_gc_write_barrier_active && !gc_dirty_pop() && !gc_software_dirty_head && !gc_software_dirty_count);
 assert(gc_write_tracking.begin() && !a.software_dirty && !b.software_dirty);
 gc_write_tracking.end();
 gc_write_tracking.disable(); assert(!gc_write_tracking.supported());
 gc_write_tracking.shutdown(); assert(!gc_write_tracking.supported());
 puts("PASS: gated Apple backend contract (host simulation)");
 return 0;
}
