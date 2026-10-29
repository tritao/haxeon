#include <hl.h>
#include <hlprof.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

/* Built with the compiler's function instrumentation and libhlprof_hooks.a: each call of work() makes the hooks record an
   enter and an exit while a session records. A forked child has no consumer, so it must record none, or it would wait
   for a chunk of the full pool forever. */

static int __attribute__((noinline)) work( int n ) {
	return n + 1;
}

static int check( int ok, const char *what ) {
	if( !ok ) fprintf(stderr,"FAIL: %s\n",what);
	return ok;
}

int main(void) {
	int marker = 0, total = 0;
	hl_global_init();
	hl_register_thread(&marker);
	if( !check(hl_prof_start(1),"a one MiB pool starts a session") ) return 1;
	for(int i=0;i<10;i++) total += work(i);

	pid_t child = fork();
	if( child < 0 ) return 1;
	if( child == 0 ) {
		/* Several times the pool: each call is an enter and an exit record. */
		for(int i=0;i<4000000;i++) total += work(i);
		_exit(total == 0 ? 3 : 0);
	}
	int status = 0;
	if( waitpid(child,&status,0) != child ) return 1;
	if( !check(WIFEXITED(status) && WEXITSTATUS(status) == 0,"the child runs instrumented code without recording or hanging") ) return 1;

	hl_prof_stats stats;
	hl_prof_get_stats(&stats);
	if( !check(hl_prof_session_open() && hl_prof_on,"the parent's session is still open and recording") ) return 1;
	for(int i=0;i<10;i++) total += work(i);
	hl_prof_stop();
	if( !check(total > 0,"the parent kept running") ) return 1;
	printf("PASS: a forked child runs instrumented native code without recording\n");
	return 0;
}
