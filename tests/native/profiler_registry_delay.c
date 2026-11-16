/* Test-only interposition: keep the main thread inside a registry critical section long enough to sample it.
 *
 * The VM is one executable, so a preloaded library cannot replace its hl_mutex_release; it can replace the C library's
 * pthread_mutex_unlock, which hl_mutex_release calls. An unlock on the main thread whose callers include
 * hl_module_registry_snapshot (named through the VM's exported symbols) waits first, while HL_TEST_REGISTRY_DELAY_ACTIVE is set. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int called_from_snapshot( void ) {
	void *frames[6];
	int count = backtrace(frames,6);
	/* hl_mutex_release may tail-call the unlock, leaving no frame of its own, so look at every frame: none of this library's is
	   named like the snapshot. */
	for( int i = 0; i < count; i++ ) {
		Dl_info info;
		if( dladdr(frames[i],&info) && info.dli_sname && strcmp(info.dli_sname,"hl_module_registry_snapshot") == 0 )
			return 1;
	}
	return 0;
}

int pthread_mutex_unlock( pthread_mutex_t *mutex ) {
	static int (*unlock_fn)(pthread_mutex_t *);
	static __thread int inside;
	int (*unlock)(pthread_mutex_t *) = __atomic_load_n(&unlock_fn,__ATOMIC_ACQUIRE);
	if( !unlock ) {
		unlock = dlsym(RTLD_NEXT,"pthread_mutex_unlock");
		__atomic_store_n(&unlock_fn,unlock,__ATOMIC_RELEASE);
	}
	/* `inside`: backtrace and dladdr take locks of their own. */
	if( !inside && getenv("HL_TEST_REGISTRY_DELAY_ACTIVE") && syscall(SYS_gettid) == getpid() ) {
		inside = 1;
		if( called_from_snapshot() ) {
			static int marked;
			if( !marked ) {
				const char *path = getenv("HL_TEST_REGISTRY_DELAY_MARKER");
				int fd = path ? open(path,O_WRONLY | O_CREAT | O_TRUNC,0600) : -1;
				if( fd >= 0 ) { if( write(fd,"1",1) != 1 ) _exit(2); close(fd); }
				marked = 1;
			}
			usleep(3000);
		}
		inside = 0;
	}
	return unlock(mutex);
}
