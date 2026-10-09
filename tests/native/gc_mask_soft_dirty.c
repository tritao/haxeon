/* Test interposer: keep the one-entry capability probe intact, but hide dirty
 * bits in allocator-page reads. Survival then depends on software barriers. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
ssize_t pread(int fd, void *buffer, size_t count, off_t offset) {
 static ssize_t (*real_pread)(int,void*,size_t,off_t);
 if( !real_pread ) real_pread = dlsym(RTLD_NEXT,"pread");
 ssize_t result = real_pread(fd,buffer,count,offset);
 char path[64], target[128];
 snprintf(path,sizeof(path),"/proc/self/fd/%d",fd);
 ssize_t length = readlink(path,target,sizeof(target)-1);
 if( length >= 0 ) {
  target[length] = 0;
  if( strstr(target,"/pagemap") && count > sizeof(uint64_t) && result > 0 )
   for(size_t i = 0; i < (size_t)result / sizeof(uint64_t); i++)
    ((uint64_t*)buffer)[i] &= ~(UINT64_C(1) << 55);
 }
 return result;
}
#ifdef GC_TEST_DROP_BARRIERS
/* Negative control: the same survival test must fail without either tracker. */
void hl_gc_write_barrier(void *address, size_t bytes) { (void)address; (void)bytes; }
#endif
