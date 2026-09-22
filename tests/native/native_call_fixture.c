#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define FIXTURE_API __declspec(dllexport)
#else
#include <pthread.h>
#define FIXTURE_API __attribute__((visibility("default")))
#endif

typedef struct native_fixture_options {
	int32_t count;
	double scale;
	int64_t token;
	int16_t delta;
} native_fixture_options;

typedef struct native_fixture_item {
	const char *name;
} native_fixture_item;

typedef struct native_fixture_retained_options {
	const native_fixture_item *items;
	uint32_t item_count;
	const char *const *paths;
	uint32_t path_count;
	const uint8_t *data;
	uint32_t size;
} native_fixture_retained_options;

typedef struct native_fixture_retained_container {
	native_fixture_retained_options value;
	const native_fixture_retained_options *options;
	uint32_t count;
} native_fixture_retained_container;

typedef struct native_fixture_point { int32_t x, y; } native_fixture_point;
typedef struct native_fixture_box { native_fixture_point start, end; } native_fixture_box;
typedef struct native_fixture_holder { void *required, *optional; } native_fixture_holder;
typedef struct native_fixture_arrays {
	int16_t values[3];
	uint8_t name[4];
	native_fixture_point points[2];
} native_fixture_arrays;
typedef struct native_fixture_padded { int8_t tag; int32_t value; } native_fixture_padded;
typedef struct native_fixture_gapped { int8_t tag; uint8_t reserved[7]; int32_t value; } native_fixture_gapped;

static int32_t native_fixture_borrowed_value = 42;
typedef int32_t (*native_fixture_binary_callback)( int32_t, int32_t );
typedef int32_t (*native_fixture_event_callback)( const native_fixture_point *, void * );
typedef void (*native_fixture_surface_event_callback)( uint32_t, int32_t, int32_t, void * );
typedef native_fixture_point (*native_fixture_point_callback)( native_fixture_point, native_fixture_point );
typedef native_fixture_arrays (*native_fixture_arrays_callback)( native_fixture_arrays );
typedef const char *(*native_fixture_utf8_callback)( const char * );
FIXTURE_API int32_t native_fixture_check_arrays( const native_fixture_arrays *arrays );
static native_fixture_binary_callback native_fixture_retained_callback;
static int32_t native_fixture_utf8_release_count;
static const char native_fixture_utf8_value[] = "ol\xC3\xA1 \xE2\x9C\x93";
static const char native_fixture_invalid_utf8[] = {(char)0xC0, (char)0xAF, 0};
static uint32_t native_fixture_value_handle_next = 1;
static uint32_t native_fixture_value_handle_release_total;

FIXTURE_API int32_t native_fixture_add( int32_t left, int32_t right ) {
	return left + right;
}

FIXTURE_API uint32_t native_fixture_value_handle_create( void ) {
	return native_fixture_value_handle_next++;
}

FIXTURE_API void native_fixture_value_handle_create_out( uint32_t *handle ) {
	*handle = native_fixture_value_handle_next++;
}

FIXTURE_API uint32_t native_fixture_value_handle_borrowed( void ) {
	return native_fixture_value_handle_next - 1;
}

FIXTURE_API void native_fixture_value_handle_destroy( uint32_t handle ) {
	if( handle != 0 )
		native_fixture_value_handle_release_total++;
}

FIXTURE_API uint32_t native_fixture_value_handle_release_count( void ) {
	return native_fixture_value_handle_release_total;
}

FIXTURE_API int32_t native_fixture_check_utf8( const char *value ) {
	return value != NULL && strcmp(value,native_fixture_utf8_value) == 0 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_nullable_utf8( const char *value ) {
	return value == NULL ? 42 : 0;
}

FIXTURE_API const char *native_fixture_borrowed_utf8( int32_t present ) {
	return present == 0 ? NULL : native_fixture_utf8_value;
}

FIXTURE_API char *native_fixture_owned_utf8( void ) {
	size_t length = strlen(native_fixture_utf8_value);
	char *result = (char *)malloc(length + 1);
	if( result != NULL ) memcpy(result,native_fixture_utf8_value,length + 1);
	return result;
}

FIXTURE_API void native_fixture_utf8_release( void *value ) {
	free(value);
	native_fixture_utf8_release_count++;
}

FIXTURE_API int32_t native_fixture_utf8_was_released( void ) {
	return native_fixture_utf8_release_count == 1 ? 42 : 0;
}

FIXTURE_API const char *native_fixture_invalid_utf8_result( void ) {
	return native_fixture_invalid_utf8;
}

FIXTURE_API int32_t native_fixture_call_utf8_callback( native_fixture_utf8_callback callback ) {
	const char *result = callback(native_fixture_utf8_value);
	return result != NULL && strcmp(result,native_fixture_utf8_value) == 0 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_call_invalid_utf8_callback( native_fixture_utf8_callback callback ) {
	return callback(native_fixture_invalid_utf8) == NULL ? 0 : -1;
}

FIXTURE_API int32_t native_fixture_call_callback( native_fixture_binary_callback callback, int32_t left, int32_t right ) {
	return callback == NULL ? 0 : callback(left,right);
}

typedef struct native_fixture_callback_task {
	native_fixture_binary_callback callback;
	int32_t result;
} native_fixture_callback_task;

#ifdef _WIN32
static DWORD WINAPI native_fixture_callback_thread( LPVOID value ) {
#else
static void *native_fixture_callback_thread( void *value ) {
#endif
	native_fixture_callback_task *task = (native_fixture_callback_task *)value;
	task->result = task->callback(19,23);
	return 0;
}

FIXTURE_API int32_t native_fixture_call_callback_on_thread( native_fixture_binary_callback callback ) {
	native_fixture_callback_task task = {callback, -1};
#ifdef _WIN32
	HANDLE thread = CreateThread(NULL,0,native_fixture_callback_thread,&task,0,NULL);
	if( thread == NULL ) return -1;
	WaitForSingleObject(thread,INFINITE);
	CloseHandle(thread);
#else
	pthread_t thread;
	if( pthread_create(&thread,NULL,native_fixture_callback_thread,&task) != 0 ) return -1;
	pthread_join(thread,NULL);
#endif
	return task.result;
}

FIXTURE_API int32_t native_fixture_call_event( native_fixture_event_callback callback, int32_t with_user_data ) {
	native_fixture_point event = {10, 11};
	return callback == NULL ? 0 : callback(&event,with_user_data ? &native_fixture_borrowed_value : NULL);
}

FIXTURE_API int32_t native_fixture_call_surface_event( native_fixture_surface_event_callback callback, void *user_data ) {
	if( callback == NULL ) return 42;
	callback(7,320,240,user_data);
	return 42;
}

FIXTURE_API int32_t native_fixture_call_point_callback( native_fixture_point_callback callback ) {
	native_fixture_point left = {10, 11}, right = {20, 21};
	native_fixture_point result = callback(left,right);
	return result.x == 30 && result.y == 32 ? 42 : 0;
}

typedef struct native_fixture_point_callback_task {
	native_fixture_point_callback callback;
	native_fixture_point result;
} native_fixture_point_callback_task;

#ifdef _WIN32
static DWORD WINAPI native_fixture_point_callback_thread( LPVOID value ) {
#else
static void *native_fixture_point_callback_thread( void *value ) {
#endif
	native_fixture_point_callback_task *task = (native_fixture_point_callback_task *)value;
	native_fixture_point left = {10, 11}, right = {20, 21};
	task->result = task->callback(left,right);
	return 0;
}

FIXTURE_API int32_t native_fixture_call_point_callback_on_thread( native_fixture_point_callback callback ) {
	native_fixture_point_callback_task task = {callback, {-1, -1}};
#ifdef _WIN32
	HANDLE thread = CreateThread(NULL,0,native_fixture_point_callback_thread,&task,0,NULL);
	if( thread == NULL ) return -1;
	WaitForSingleObject(thread,INFINITE);
	CloseHandle(thread);
#else
	pthread_t thread;
	if( pthread_create(&thread,NULL,native_fixture_point_callback_thread,&task) != 0 ) return -1;
	pthread_join(thread,NULL);
#endif
	return task.result.x == 0 && task.result.y == 0 ? 0 : -1;
}

FIXTURE_API int32_t native_fixture_call_arrays_callback( native_fixture_arrays_callback callback ) {
	native_fixture_arrays value = {{10, 11, 12}, {'A', 'B', 'C', 'D'}, {{10, 11}, {20, 21}}};
	native_fixture_arrays result = callback(value);
	return native_fixture_check_arrays(&result);
}

FIXTURE_API int32_t native_fixture_call_invalid_event( native_fixture_event_callback callback ) {
	return callback == NULL ? 0 : callback(NULL,NULL);
}

FIXTURE_API void native_fixture_set_callback( native_fixture_binary_callback callback ) {
	native_fixture_retained_callback = callback;
}

FIXTURE_API void native_fixture_clear_callback( void ) {
	native_fixture_retained_callback = NULL;
}

FIXTURE_API int32_t native_fixture_call_retained_callback( int32_t left, int32_t right ) {
	return native_fixture_retained_callback == NULL ? 0 : native_fixture_retained_callback(left,right);
}

FIXTURE_API int32_t native_fixture_check_options( const native_fixture_options *options ) {
	return options != NULL && options->count == 40 && options->scale == 1.5
		&& options->token == INT64_C(0x10000002A) && options->delta == 2 ? 42 : 0;
}

static int32_t native_fixture_retained_options_valid( const native_fixture_retained_options *options ) {
	static const uint8_t expected[] = {'b', 'u', 'f', 'f', 'e', 'r', '!'};
	return options != NULL && options->item_count == 1 && options->items != NULL
		&& options->items[0].name != NULL && strcmp(options->items[0].name,"retained-entry") == 0
		&& options->path_count == 2 && options->paths != NULL
		&& strcmp(options->paths[0],"alpha") == 0 && strcmp(options->paths[1],"beta") == 0
		&& options->size == sizeof(expected) && options->data != NULL
		&& memcmp(options->data,expected,sizeof(expected)) == 0;
}

FIXTURE_API int32_t native_fixture_check_retained_container( const native_fixture_retained_container *container,
	const native_fixture_retained_options *extracted ) {
	return container != NULL && container->count == 1 && container->options != NULL
		&& native_fixture_retained_options_valid(&container->value)
		&& native_fixture_retained_options_valid(&container->options[0])
		&& native_fixture_retained_options_valid(extracted) ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_box( const native_fixture_box *box ) {
	return box != NULL && box->start.x == 10 && box->start.y == 11 && box->end.x == 20 && box->end.y == 21 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_holder( const native_fixture_holder *holder ) {
	return holder != NULL && holder->required == &native_fixture_borrowed_value && holder->optional == NULL ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_arrays( const native_fixture_arrays *arrays ) {
	return arrays != NULL && arrays->values[0] == 10 && arrays->values[2] == 12
		&& arrays->name[0] == 'A' && arrays->name[3] == 'D'
		&& arrays->points[0].x == 10 && arrays->points[1].y == 21 ? 42 : 0;
}

FIXTURE_API native_fixture_point native_fixture_add_points( native_fixture_point left, native_fixture_point right ) {
	native_fixture_point result = {left.x + right.x, left.y + right.y};
	return result;
}

FIXTURE_API int32_t native_fixture_get_point( int32_t base, native_fixture_point *point ) {
	if( point == NULL ) return -1;
	point->x = base;
	point->y = base + 2;
	return 42;
}

FIXTURE_API void native_fixture_double_value( int32_t *value ) {
	if( value != NULL ) *value *= 2;
}

FIXTURE_API int32_t native_fixture_shift_point( native_fixture_point *point ) {
	if( point == NULL ) return -1;
	point->x += 1;
	point->y += 1;
	return 42;
}

FIXTURE_API int32_t native_fixture_read_bytes( int32_t first, uint8_t *data, uint32_t *size ) {
	const uint32_t required = 3;
	if( size == NULL ) return -1;
	if( data == NULL || *size < required ) {
		*size = required;
		return 1;
	}
	data[0] = (uint8_t)first;
	data[1] = 41;
	data[2] = 42;
	*size = required;
	return 42;
}

FIXTURE_API int32_t native_fixture_map_points( const native_fixture_point *values, uint64_t count,
		native_fixture_point *results ) {
	if( count > 1024 || (count != 0 && (values == NULL || results == NULL)) ) return 0;
	for( uint64_t index = 0; index < count; ++index ) {
		results[index].x = values[index].x + 1;
		results[index].y = values[index].y + 2;
	}
	return 42;
}

FIXTURE_API int32_t native_fixture_map_values( const int16_t *values, uint64_t count, uint16_t *results ) {
	if( count > 1024 || (count != 0 && (values == NULL || results == NULL)) ) return 0;
	for( uint64_t index = 0; index < count; ++index )
		results[index] = (uint16_t)(values[index] * 2);
	return 42;
}

FIXTURE_API int32_t native_fixture_fill_values( uint64_t count, uint32_t *results ) {
	if( count > 1024 || (count != 0 && results == NULL) ) return 0;
	for( uint64_t index = 0; index < count; ++index )
		results[index] = (uint32_t)(index + 10);
	return 42;
}

FIXTURE_API int32_t native_fixture_check_box_value( native_fixture_box box ) {
	return box.start.x == 10 && box.start.y == 11 && box.end.x == 20 && box.end.y == 21 ? 42 : 0;
}

FIXTURE_API int32_t native_fixture_check_arrays_value( native_fixture_arrays arrays ) {
	return native_fixture_check_arrays(&arrays);
}

FIXTURE_API native_fixture_padded native_fixture_make_padded( int32_t value ) {
	native_fixture_padded result = {(int8_t)2, value};
	return result;
}

FIXTURE_API native_fixture_gapped native_fixture_make_gapped( int32_t value ) {
	native_fixture_gapped result = {(int8_t)3, {0}, value};
	return result;
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
static int32_t native_fixture_out_release_count;
static const uint8_t native_fixture_borrowed_bytes[] = {40, 41, 42};

FIXTURE_API void *native_fixture_owned( int32_t value ) {
	int32_t *result = (int32_t *)malloc(sizeof(int32_t));
	if( result != NULL ) *result = value;
	return result;
}

FIXTURE_API void native_fixture_owned_out( int32_t value, int32_t **result ) {
	if( result == NULL ) return;
	if( value == 0 ) { *result = NULL; return; }
	int32_t *owned = (int32_t *)malloc(sizeof(int32_t));
	if( owned != NULL ) *owned = value;
	*result = owned;
}

FIXTURE_API void native_fixture_borrowed_out( int32_t present, int32_t **result ) {
	if( result != NULL ) *result = present == 0 ? NULL : &native_fixture_borrowed_value;
}

FIXTURE_API void native_fixture_out_release( void *value ) {
	free(value);
	native_fixture_out_release_count++;
}

FIXTURE_API int32_t native_fixture_out_was_released( void ) {
	return native_fixture_out_release_count == 1 ? 42 : 0;
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
