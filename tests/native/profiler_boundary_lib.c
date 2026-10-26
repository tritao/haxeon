#include <stdarg.h>

/* Functions the boundary thunk must pass through unchanged: arguments in registers and on the stack, results in rax, rdx,
   xmm0 and xmm1 and in memory, and a variadic callee that reads the vector registers. */

typedef struct { long a, b, c; } big;
typedef struct { long a, b; } pair;
typedef struct { double x, y; } dpair;

long many_ints( long a, long b, long c, long d, long e, long f, long g, long h, long i, long j ) {
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j;
}

double many_doubles( double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7, double d8, double d9 ) {
	return d0 + 2 * d1 + 3 * d2 + 4 * d3 + 5 * d4 + 6 * d5 + 7 * d6 + 8 * d7 + 9 * d8 + 10 * d9;
}

double mixed( int i0, int i1, int i2, int i3, int i4, int i5, double d0, double d1, double d2, double d3, double d4, double d5, double d6,
	double d7, long s0, double s1, long s2 ) {
	return i0 + 2 * i1 + 3 * i2 + 4 * i3 + 5 * i4 + 6 * i5 + d0 + 2 * d1 + 3 * d2 + 4 * d3 + 5 * d4 + 6 * d5 + 7 * d6 + 8 * d7 + s0 + 3 * s1 + s2;
}

big make_big( long a, long b, long c ) {
	big r = { a * 2, b * 3, c * 5 };
	return r;
}

pair make_pair( long a, long b ) {
	pair r = { a + b, a - b };
	return r;
}

dpair make_dpair( double x, double y ) {
	dpair r = { x * 2, y * 3 };
	return r;
}

double sum_va( int n, ... ) {
	va_list args;
	double total = 0;
	va_start(args,n);
	for(int i=0;i<n;i++) total += va_arg(args,double);
	va_end(args);
	return total;
}

/* Called only from a library the program loads after the hooks are installed. */
long late_only( long x ) {
	return x + 1;
}
