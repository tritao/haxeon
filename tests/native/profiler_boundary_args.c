#include <dlfcn.h>
#include <hl.h>
#include <hlmodule.h>
#include <hlprof.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The boundary hooks (prof_boundary_linux.c) make a call into one of our own shared objects a slice named after the
   function, and the thunk that records it must hand the real function exactly the arguments it was called with and return
   exactly its result, whatever the registers and the stack held. libboundarylib.so is called through the program's PLT. */

typedef struct { long a, b, c; } big;
typedef struct { long a, b; } pair;
typedef struct { double x, y; } dpair;

long many_ints( long, long, long, long, long, long, long, long, long, long );
double many_doubles( double, double, double, double, double, double, double, double, double, double );
double mixed( int, int, int, int, int, int, double, double, double, double, double, double, double, double, long, double, long );
big make_big( long, long, long );
pair make_pair( long, long );
dpair make_dpair( double, double );
double sum_va( int, ... );

static int failures;

static void check( int ok, const char *what ) {
	if( !ok ) { fprintf(stderr,"FAIL: %s\n",what); failures++; }
}

static void call_all( void ) {
	check(many_ints(1,2,3,4,5,6,7,8,9,10) == 385,"ten integer arguments, four on the stack");
	check(many_doubles(1,2,3,4,5,6,7,8,9,10) == 385.0,"ten double arguments, two on the stack");
	{
		double expected = 1 + 4 + 9 + 16 + 25 + 36 + 1 + 4 + 9 + 16 + 25 + 36 + 49 + 64 + 100 + 7.5 + 1000;
		check(mixed(1,2,3,4,5,6,1,2,3,4,5,6,7,8,100,2.5,1000) == expected,"integers, doubles and stack arguments together");
	}
	{
		big b = make_big(1,2,3);
		check(b.a == 2 && b.b == 6 && b.c == 15,"a struct returned in memory");
		pair p = make_pair(7,3);
		check(p.a == 10 && p.b == 4,"a struct returned in rax and rdx");
		dpair d = make_dpair(1.5,2.0);
		check(d.x == 3.0 && d.y == 6.0,"a struct returned in xmm0 and xmm1");
	}
	check(sum_va(4,1.5,2.5,3.5,4.5) == 12.0,"a variadic callee reading vector registers");
}

static int named( const char *names, const char *name ) {
	size_t n = strlen(name);
	for(const char *p = names; (p = strstr(p,name)); p++)
		if( (p == names || p[-1] == ' ') && p[n] == ' ' ) return 1;
	return 0;
}

int main(void) {
	int marker = 0;
	char names[1024] = "";
	unsigned long long keys[64];
	int count;
	hl_global_init();
	hl_register_thread(&marker);
	setenv("HL_PROF_BOUNDARY","imports=none;extra=libboundarylib.so!many_ints,libboundarylib.so!many_doubles,libboundarylib.so!mixed,"
		"libboundarylib.so!make_big,libboundarylib.so!make_pair,libboundarylib.so!make_dpair,libboundarylib.so!sum_va,"
		"libboundarylib.so!late_only",1);
	hl_prof_boundary_install();

	/* Hooked, and not recording: the thunk only passes the call through. */
	call_all();

	if( !hl_prof_start(1) ) return 2;
	call_all();
	/* An object loaded after the hooks were installed is patched too: this call is the only one of late_only. */
	{
		void *late = dlopen("libboundarylate.so",RTLD_NOW);
		long (*late_call)( long ) = late ? (long (*)( long ))dlsym(late,"late_call") : NULL;
		check(late_call != NULL,"the late library loads");
		if( late_call ) check(late_call(20) == 42,"a call through a library loaded later");
	}
	hl_prof_stop();

	/* Every hooked function recorded, and was named by the library it is in. */
	count = hl_prof_native_keys_take(keys,64);
	for(int i=0;i<count;i++) {
		const char *name = hl_prof_boundary_name(keys[i]);
		if( name ) { strcat(names,name); strcat(names," "); }
	}
	check(count == 8,"eight hooked functions are recorded");
	for(int i=0;i<8;i++) {
		static const char *const expected[] = { "libboundarylib!many_ints", "libboundarylib!many_doubles", "libboundarylib!mixed",
			"libboundarylib!make_big", "libboundarylib!make_pair", "libboundarylib!make_dpair", "libboundarylib!sum_va",
			"libboundarylib!late_only" };
		check(named(names,expected[i]),expected[i]);
	}
	if( failures ) return 1;
	printf("PASS: the boundary thunk passes arguments and results through unchanged\n");
	return 0;
}
