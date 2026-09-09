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
