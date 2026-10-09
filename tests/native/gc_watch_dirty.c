/* Observe a selected page's kernel capture, without changing its dirty bits. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
static off_t watched = -1;
static int seen;
void gc_test_watch_dirty(void *address) {
 watched = (off_t)((uintptr_t)address / sysconf(_SC_PAGESIZE)) * sizeof(uint64_t);
 seen = 0;
}
int gc_test_dirty_seen(void) { return seen; }
ssize_t pread(int fd, void *buffer, size_t count, off_t offset) {
 static ssize_t (*read_real)(int,void*,size_t,off_t);
 if(!read_real) read_real = dlsym(RTLD_NEXT,"pread");
 ssize_t result = read_real(fd,buffer,count,offset);
 /* This process only uses pread for pagemap; watch is armed after probing. */
 if(result > 0 && watched >= offset && watched < offset + result) {
  if(seen && getenv("HL_GC_TEST_HIDE_WATCHED_REVISITS"))
   ((uint64_t*)buffer)[(watched-offset)/sizeof(uint64_t)] &= ~(UINT64_C(1)<<55);
  seen = 1;
 }
 return result;
}
