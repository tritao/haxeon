#include <hl.h>
#include <hlprof.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* A forked child of a recording process must stop recording: the consumer is not in the child, so records written there
   have nowhere to go and a writer would wait for a chunk forever once the pool is full. The parent keeps recording. */

static const char name[] = "span";

static void record_spans( int count ) {
	for(int i=0;i<count;i++) {
		hl_prof_span_begin(name,(int)strlen(name),HL_PROF_UTF8);
		hl_prof_span_end();
	}
}

static void count_segment( void *context, unsigned int tid, const unsigned char *data, unsigned int length ) {
	(void)tid;
	(void)data;
	*(unsigned long long*)context += length;
}

static int check( int ok, const char *what ) {
	if( !ok ) fprintf(stderr,"FAIL: %s\n",what);
	return ok;
}

int main(void) {
	int marker = 0;
	hl_global_init();
	hl_register_thread(&marker);
	if( !check(hl_prof_start(1),"a one MiB pool starts a session") ) return 1;
	record_spans(10);

	pid_t child = fork();
	if( child < 0 ) return 1;
	if( child == 0 ) {
		/* Far more than the 1 MiB pool holds, with no consumer: this hangs unless the child records nothing. */
		int stopped = !hl_prof_session_open() && !hl_prof_on;
		record_spans(4000000);
		hl_prof_stop();
		_exit(stopped ? 0 : 3);
	}

	int status = 0;
	if( waitpid(child,&status,0) != child ) return 1;
	if( !check(WIFEXITED(status) && WEXITSTATUS(status) == 0,"the child records nothing and sees no open session") ) return 1;
	if( !check(hl_prof_session_open() && hl_prof_on,"the parent's session is still open and recording") ) return 1;

	unsigned long long before = 0, after = 0;
	hl_prof_drain(count_segment,&before);
	record_spans(10);
	hl_prof_drain(count_segment,&after);
	if( !check(before > 0 && after > 0,"the parent still records and drains after the fork") ) return 1;

	/* A child may start a session of its own. */
	child = fork();
	if( child < 0 ) return 1;
	if( child == 0 ) {
		int ok = hl_prof_start(1);
		record_spans(10);
		unsigned long long bytes = 0;
		hl_prof_drain(count_segment,&bytes);
		hl_prof_stop();
		_exit(ok && bytes > 0 ? 0 : 4);
	}
	if( waitpid(child,&status,0) != child ) return 1;
	if( !check(WIFEXITED(status) && WEXITSTATUS(status) == 0,"a child can start and drain a session of its own") ) return 1;

	hl_prof_stop();
	printf("PASS: a forked child stops recording and the parent keeps its session\n");
	return 0;
}
