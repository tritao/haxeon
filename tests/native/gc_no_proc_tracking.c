/* Fail the test if the software backend attempts to open either kernel tracker. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int checked_open(const char *path, int flags, mode_t mode, const char *symbol) {
 if (!strcmp(path,"/proc/self/pagemap") || !strcmp(path,"/proc/self/clear_refs")) {
  if (getenv("HL_GC_TEST_DENY_PROC")) { errno = EACCES; return -1; }
  fputs("FAIL: software GC attempted kernel tracking\n",stderr);
  _exit(90);
 }
 int (*real_open)(const char*,int,...) = dlsym(RTLD_NEXT,symbol);
 return real_open(path,flags,mode);
}
#define WRAP_OPEN(name) \
int name(const char *path, int flags, ...) { \
 mode_t mode = 0; \
 if ((flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE) { \
  va_list args; va_start(args,flags); mode = va_arg(args,mode_t); va_end(args); \
 } \
 return checked_open(path,flags,mode,#name); \
}
WRAP_OPEN(open)
WRAP_OPEN(open64)
