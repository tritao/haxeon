/* Test-only interposition: keep the main thread inside a registry critical section long enough to sample it. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

void hl_mutex_release(void *mutex) {
    static void (*release_fn)(void *);
    void (*release)(void *) = __atomic_load_n(&release_fn, __ATOMIC_ACQUIRE);
    if (!release) {
        release = dlsym(RTLD_NEXT, "hl_mutex_release");
        __atomic_store_n(&release_fn, release, __ATOMIC_RELEASE);
    }
    if (getenv("HL_TEST_REGISTRY_DELAY_ACTIVE") && syscall(SYS_gettid) == getpid()) {
        Dl_info info;
        if (dladdr(__builtin_return_address(0), &info) && info.dli_sname &&
            strcmp(info.dli_sname, "hl_module_registry_snapshot") == 0) {
            static int marked;
            if (!marked) {
                const char *path = getenv("HL_TEST_REGISTRY_DELAY_MARKER");
                int fd = path ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600) : -1;
                if (fd >= 0) { if (write(fd, "1", 1) != 1) _exit(2); close(fd); }
                marked = 1;
            }
            usleep(3000);
        }
    }
    release(mutex);
}
