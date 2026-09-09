#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
#define FIXTURE_API __declspec(dllexport)
#else
#define FIXTURE_API __attribute__((visibility("default")))
#endif

FIXTURE_API int32_t native_fixture_add( int32_t left, int32_t right ) {
	return left + right;
}

FIXTURE_API double native_fixture_multiply( double left, double right ) {
	return left * right;
}

FIXTURE_API int32_t native_fixture_is_null( const void *value ) {
	return value == NULL ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_sum16( int32_t a0, int32_t a1, int32_t a2, int32_t a3,
	int32_t a4, int32_t a5, int32_t a6, int32_t a7, int32_t a8, int32_t a9,
	int32_t a10, int32_t a11, int32_t a12, int32_t a13, int32_t a14, int32_t a15 ) {
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15;
}
