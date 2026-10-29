#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* A C++ exception thrown through a hooked function, and the cancellation of a thread blocked in a hooked call, both unwind
   through the boundary thunk, which carries unwind information. The exit record it skips is missing, as on Windows. */

extern "C" {
void hl_global_init( void );
void hl_register_thread( void *stack_top );
void hl_unregister_thread( void );
void hl_prof_boundary_install( void );
bool hl_prof_start( unsigned int pool_mib );
void hl_prof_stop( void );
}
extern "C" void thrower( int value );

static int failures;

static void check( bool ok, const char *what ) {
	if( !ok ) { fprintf(stderr,"FAIL: %s\n",what); failures++; }
}

static void *sleeper( void * ) {
	int marker = 0;
	hl_register_thread(&marker);
	usleep(30 * 1000 * 1000);
	/* Not reached: the cancellation unwinds out of the hooked usleep. */
	hl_unregister_thread();
	return NULL;
}

int main() {
	int marker = 0, caught = 0;
	hl_global_init();
	hl_register_thread(&marker);
	setenv("HL_PROF_BOUNDARY","imports=blocking;extra=libboundarythrow.so!thrower",1);
	hl_prof_boundary_install();
	if( !hl_prof_start(1) ) return 2;

	try {
		thrower(42);
	} catch( int value ) {
		caught = value;
	}
	check(caught == 42,"an exception thrown through a hooked function is caught by its caller");

	pthread_t thread;
	void *result = NULL;
	pthread_create(&thread,NULL,sleeper,NULL);
	usleep(100 * 1000);
	pthread_cancel(thread);
	pthread_join(thread,&result);
	check(result == PTHREAD_CANCELED,"a thread cancelled in a hooked usleep ends");

	hl_prof_stop();
	if( failures ) return 1;
	printf("PASS: exceptions and cancellation unwind through the boundary thunk\n");
	return 0;
}
