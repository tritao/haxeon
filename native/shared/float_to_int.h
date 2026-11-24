#ifndef FLOAT_TO_INT_H
#define FLOAT_TO_INT_H

#include <stdint.h>

/*
 * A float converted to an integer, rounded toward zero, as the JIT converts it (OToInt), for the runtime's natives and the C of an
 * ahead-of-time build. C leaves the conversion of a value out of the integer's range, NaN included, undefined, and an optimizer may
 * fold one to anything; these give what the instruction the JIT emits gives instead: on ARM64 the nearest integer of the range,
 * and 0 for NaN (FCVTZS); on x86-64 the most negative integer (CVTTSD2SI's "integer indefinite").
 */
static inline int float_to_int( double value ) {
#if defined(__aarch64__) || defined(_M_ARM64)
	if( value != value ) return 0;
	if( value >= 2147483647.0 ) return INT32_MAX;
	if( value <= -2147483648.0 ) return INT32_MIN;
	return (int)value;
#else
	return value > -2147483649.0 && value < 2147483648.0 ? (int)value : INT32_MIN;
#endif
}

static inline int64_t float_to_int64( double value ) {
#if defined(__aarch64__) || defined(_M_ARM64)
	if( value != value ) return 0;
	if( value >= 9223372036854775807.0 ) return INT64_MAX;
	if( value <= -9223372036854775808.0 ) return INT64_MIN;
	return (int64_t)value;
#else
	return value >= -9223372036854775808.0 && value < 9223372036854775808.0 ? (int64_t)value : INT64_MIN;
#endif
}

#endif
