/* No-op profiler boundary hooks for Android. HashLink's prof_boundary.c patches glibc imports on Linux x86-64,
 * which also matches the Android x86_64 emulator ABI but not Bionic. */
void hl_prof_boundary_install(void) {}
void hl_prof_boundary_ignore_thread(void) {}
const char *hl_prof_boundary_name(unsigned long long key) { (void)key; return 0; }
