#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

#ifdef _WIN32
#define FIXTURE_API __declspec(dllexport)
#else
#define FIXTURE_API __attribute__((visibility("default")))
#endif

typedef struct native_fixture_options {
	int32_t count;
	double scale;
	int64_t token;
	int16_t delta;
} native_fixture_options;

typedef struct native_fixture_point { int32_t x, y; } native_fixture_point;
typedef struct native_fixture_box { native_fixture_point start, end; } native_fixture_box;
typedef struct native_fixture_holder { void *required, *optional; } native_fixture_holder;

static int32_t native_fixture_borrowed_value = 42;

FIXTURE_API int32_t native_fixture_add( int32_t left, int32_t right ) {
	return left + right;
}

FIXTURE_API int32_t native_fixture_check_options( const native_fixture_options *options ) {
	return options != NULL && options->count == 40 && options->scale == 1.5
		&& options->token == INT64_C(0x10000002A) && options->delta == 2 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_box( const native_fixture_box *box ) {
	return box != NULL && box->start.x == 10 && box->start.y == 11 && box->end.x == 20 && box->end.y == 21 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_holder( const native_fixture_holder *holder ) {
	return holder != NULL && holder->required == &native_fixture_borrowed_value && holder->optional == NULL ? 42 : 0;
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

FIXTURE_API int64_t native_fixture_i64_value( void ) {
	return INT64_C(0x10000002A);
}

FIXTURE_API int32_t native_fixture_i64_check( int64_t value ) {
	return value == INT64_C(0x10000002A) ? 42 : 0;
}

static int32_t native_fixture_release_count;
static int32_t native_fixture_data_release_count;
static const uint8_t native_fixture_borrowed_bytes[] = {40, 41, 42};

FIXTURE_API void *native_fixture_owned( int32_t value ) {
	int32_t *result = (int32_t *)malloc(sizeof(int32_t));
	if( result != NULL ) *result = value;
	return result;
}

FIXTURE_API void native_fixture_release( void *value ) {
	free(value);
	native_fixture_release_count++;
}

FIXTURE_API void *native_fixture_borrowed( void ) {
	return &native_fixture_borrowed_value;
}

FIXTURE_API void *native_fixture_maybe_borrowed( int32_t present ) {
	return present == 0 ? NULL : &native_fixture_borrowed_value;
}

FIXTURE_API void *native_fixture_invalid_non_null( void ) {
	return NULL;
}

FIXTURE_API int32_t native_fixture_pointer_value( const int32_t *value ) {
	return value == NULL ? 0 : *value;
}

FIXTURE_API int32_t native_fixture_was_released( void ) {
	return native_fixture_release_count == 1 ? 42 : 0;
}

FIXTURE_API uint8_t *native_fixture_owned_data( int32_t first ) {
	uint8_t *data = (uint8_t *)malloc(3);
	if( data != NULL ) {
		data[0] = (uint8_t)first;
		data[1] = 41;
		data[2] = 42;
	}
	return data;
}

FIXTURE_API void native_fixture_data_release( void *value ) {
	free(value);
	native_fixture_data_release_count++;
}

FIXTURE_API const uint8_t *native_fixture_borrowed_data( int32_t present ) {
	return present == 0 ? NULL : native_fixture_borrowed_bytes;
}

FIXTURE_API size_t native_fixture_data_length( int32_t ignored ) {
	(void)ignored;
	return 3;
}

FIXTURE_API int32_t native_fixture_data_was_released( void ) {
	return native_fixture_data_release_count == 1 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_data_check( const uint8_t *data ) {
	return data != NULL && data[0] == 40 && data[1] == 41 && data[2] == 42 ? 42 : 0;
}

FIXTURE_API const uint8_t *native_fixture_invalid_data( void ) {
	return native_fixture_borrowed_bytes;
}

FIXTURE_API size_t native_fixture_invalid_data_length( void ) {
	return SIZE_MAX;
}
