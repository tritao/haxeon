#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>
#include <string.h>
#include <stdlib.h>

typedef struct realtime_string_map realtime_string_map;
extern realtime_string_map *hl_hballoc( void );
extern void hl_hbset( realtime_string_map *map, uchar *key, vdynamic *value );
extern bool hl_hbexists( realtime_string_map *map, uchar *key );
extern vdynamic *hl_hbget( realtime_string_map *map, uchar *key );
extern varray *hl_hbkeys( realtime_string_map *map );
extern varray *hl_hbvalues( realtime_string_map *map );
extern int hl_hbsize( realtime_string_map *map );
extern bool hl_hbremove( realtime_string_map *map, uchar *key );
extern void hl_hbclear( realtime_string_map *map );

static void realtime_raise_module_exception( void ) {
	/* A module exception owns generation-specific type metadata. Never let that
	   value escape into the host exception machinery after the call returns. */
	hl_thread_info *thread = hl_get_thread();
	thread->exc_value = NULL;
	thread->exc_stack_count = 0;
	memset(thread->exc_stack_trace,0,sizeof(thread->exc_stack_trace));
	hl_error("Runtime module call raised an exception");
}

typedef struct realtime_int_map realtime_int_map;
extern realtime_int_map *hl_hialloc( void );
extern void hl_hiset( realtime_int_map *map, int key, vdynamic *value );
extern bool hl_hiexists( realtime_int_map *map, int key );
extern vdynamic *hl_higet( realtime_int_map *map, int key );
extern varray *hl_hikeys( realtime_int_map *map );
extern varray *hl_hivalues( realtime_int_map *map );
extern int hl_hisize( realtime_int_map *map );
extern bool hl_hiremove( realtime_int_map *map, int key );
extern void hl_hiclear( realtime_int_map *map );

typedef struct {
	void (*finalize)( void * );
	vbyte *data;
	int length;
} realtime_bytes;

typedef struct {
	void (*finalize)( void * );
	vbyte *data;
	int length;
	int position;
	bool big_endian;
} realtime_bytes_input;

typedef struct {
	void (*finalize)( void * );
	vbyte *data;
	int length;
	int capacity;
	bool big_endian;
} realtime_bytes_output;

typedef struct { double milliseconds; } realtime_date;
extern double hl_sys_time( void );

HL_PRIM realtime_date *HL_NAME(__date_now)( void ) {
	realtime_date *date = (realtime_date *)hl_gc_alloc_raw(sizeof(realtime_date));
	date->milliseconds = hl_sys_time() * 1000.0;
	return date;
}

HL_PRIM double HL_NAME(__date_get_time)( realtime_date *date ) { return date->milliseconds; }

static void realtime_bytes_finalize( void *value ) {
	realtime_bytes *bytes = (realtime_bytes *)value;
	free(bytes->data);
	bytes->data = NULL;
}

static void realtime_bytes_output_finalize( void *value ) {
	realtime_bytes_output *output = (realtime_bytes_output *)value;
	free(output->data);
	output->data = NULL;
}

static void realtime_bytes_input_finalize( void *value ) {
	realtime_bytes_input *input = (realtime_bytes_input *)value;
	free(input->data);
	input->data = NULL;
}

static realtime_bytes *realtime_bytes_make( int length ) {
	if( length < 0 ) hl_error("Negative byte length");
	realtime_bytes *bytes = (realtime_bytes *)hl_gc_alloc_finalizer(sizeof(realtime_bytes));
	bytes->finalize = realtime_bytes_finalize;
	bytes->length = length;
	bytes->data = length == 0 ? NULL : (vbyte *)calloc((size_t)length, 1);
	if( length > 0 && bytes->data == NULL ) hl_error("Could not allocate bytes");
	return bytes;
}

static void realtime_bytes_bounds( realtime_bytes *bytes, int position, int length ) {
	if( bytes == NULL || position < 0 || length < 0 || position > bytes->length - length )
		hl_error("Bytes access out of bounds");
}

static void realtime_bytes_output_reserve( realtime_bytes_output *output, int extra ) {
	if( extra < 0 || output->length > 0x7FFFFFFF - extra ) hl_error("Byte output is too large");
	int required = output->length + extra;
	if( required <= output->capacity ) return;
	int capacity = output->capacity == 0 ? 64 : output->capacity;
	while( capacity < required ) {
		if( capacity > 0x3FFFFFFF ) { capacity = required; break; }
		capacity *= 2;
	}
	vbyte *data = (vbyte *)realloc(output->data, (size_t)capacity);
	if( data == NULL ) hl_error("Could not grow byte output");
	output->data = data;
	output->capacity = capacity;
}

HL_PRIM realtime_bytes *HL_NAME(__bytes_alloc)( int length ) {
	return realtime_bytes_make(length);
}

HL_PRIM realtime_bytes *HL_NAME(__bytes_of_string)( vbyte *value ) {
	const char *utf8 = value == NULL ? "" : hl_to_utf8((const uchar *)value);
	int length = (int)strlen(utf8);
	realtime_bytes *bytes = realtime_bytes_make(length);
	if( length > 0 ) memcpy(bytes->data, utf8, (size_t)length);
	return bytes;
}

HL_PRIM int HL_NAME(__bytes_length)( realtime_bytes *bytes ) { return bytes == NULL ? 0 : bytes->length; }
HL_PRIM int HL_NAME(__bytes_get)( realtime_bytes *bytes, int position ) {
	realtime_bytes_bounds(bytes, position, 1);
	return bytes->data[position];
}
HL_PRIM void HL_NAME(__bytes_set)( realtime_bytes *bytes, int position, int value ) {
	realtime_bytes_bounds(bytes, position, 1);
	bytes->data[position] = (vbyte)value;
}
HL_PRIM void HL_NAME(__bytes_set_i32)( realtime_bytes *bytes, int position, int value ) {
	realtime_bytes_bounds(bytes, position, 4);
	for( int i = 0; i < 4; i++ ) bytes->data[position + i] = (vbyte)(value >> (i * 8));
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_sub)( realtime_bytes *bytes, int position, int length ) {
	realtime_bytes_bounds(bytes, position, length);
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data, bytes->data + position, (size_t)length);
	return result;
}
HL_PRIM int HL_NAME(__bytes_compare)( realtime_bytes *left, realtime_bytes *right ) {
	int common = left->length < right->length ? left->length : right->length;
	int compared = common == 0 ? 0 : memcmp(left->data, right->data, (size_t)common);
	return compared != 0 ? compared : left->length - right->length;
}
HL_PRIM vbyte *HL_NAME(__bytes_to_string)( realtime_bytes *bytes ) {
	char *utf8 = (char *)malloc((size_t)bytes->length + 1);
	if( utf8 == NULL ) hl_error("Could not allocate byte string");
	if( bytes->length > 0 ) memcpy(utf8, bytes->data, (size_t)bytes->length);
	utf8[bytes->length] = 0;
	int chars = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	free(utf8);
	return (vbyte *)result;
}

static vbyte *realtime_string_from_utf8( const char *utf8 ) {
	int chars = hl_utf8_length((const vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	return (vbyte *)result;
}

HL_PRIM varray *HL_NAME(__sys_args)( void ) {
	varray *result = hl_alloc_array(&hlt_bytes, hl_setup.sys_nargs);
	vbyte **arguments = hl_aptr(result, vbyte *);
	for( int index = 0; index < hl_setup.sys_nargs; index++ ) {
#ifdef HL_WIN
		arguments[index] = (vbyte *)hl_setup.sys_args[index];
#else
		arguments[index] = realtime_string_from_utf8(hl_setup.sys_args[index]);
#endif
	}
	return result;
}

HL_PRIM realtime_bytes_input *HL_NAME(__bytes_input_new)( realtime_bytes *bytes ) {
	realtime_bytes_input *input = (realtime_bytes_input *)hl_gc_alloc_finalizer(sizeof(realtime_bytes_input));
	input->finalize = realtime_bytes_input_finalize;
	input->length = bytes->length;
	input->data = bytes->length == 0 ? NULL : (vbyte *)malloc((size_t)bytes->length);
	if( bytes->length > 0 && input->data == NULL ) hl_error("Could not allocate byte input");
	if( bytes->length > 0 ) memcpy(input->data, bytes->data, (size_t)bytes->length);
	input->position = 0;
	input->big_endian = true;
	return input;
}
HL_PRIM int HL_NAME(__bytes_input_position)( realtime_bytes_input *input ) { return input->position; }
HL_PRIM bool HL_NAME(__bytes_input_big_endian)( realtime_bytes_input *input ) { return input->big_endian; }
HL_PRIM void HL_NAME(__bytes_input_set_big_endian)( realtime_bytes_input *input, bool value ) { input->big_endian = value; }
HL_PRIM int HL_NAME(__bytes_input_read_byte)( realtime_bytes_input *input ) {
	if( input->position < 0 || input->position >= input->length ) hl_error("Byte input is truncated");
	return input->data[input->position++];
}
HL_PRIM int HL_NAME(__bytes_input_read_i32)( realtime_bytes_input *input ) {
	if( input->position < 0 || input->position > input->length - 4 ) hl_error("Byte input is truncated");
	vbyte *data = input->data + input->position;
	input->position += 4;
	if( input->big_endian ) return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
	return data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
}
HL_PRIM double HL_NAME(__bytes_input_read_f64)( realtime_bytes_input *input ) {
	union { double value; vbyte bytes[8]; } decoded;
	if( input->position < 0 || input->position > input->length - 8 ) hl_error("Byte input is truncated");
	for( int i = 0; i < 8; i++ ) decoded.bytes[i] = input->data[input->position + (input->big_endian ? 7 - i : i)];
	input->position += 8;
	return decoded.value;
}
HL_PRIM vbyte *HL_NAME(__bytes_input_read_string)( realtime_bytes_input *input, int length ) {
	if( length < 0 || input->position < 0 || input->position > input->length - length ) hl_error("Byte input is truncated");
	char *utf8 = (char *)malloc((size_t)length + 1);
	if( utf8 == NULL ) hl_error("Could not allocate string input");
	memcpy(utf8, input->data + input->position, (size_t)length);
	utf8[length] = 0;
	input->position += length;
	int chars = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((chars + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, chars, utf8);
	result[chars] = 0;
	free(utf8);
	return (vbyte *)result;
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_input_read)( realtime_bytes_input *input, int length ) {
	if( length < 0 || input->position < 0 || input->position > input->length - length ) hl_error("Byte input is truncated");
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data, input->data + input->position, (size_t)length);
	input->position += length;
	return result;
}

HL_PRIM realtime_bytes_output *HL_NAME(__bytes_output_new)( void ) {
	realtime_bytes_output *output = (realtime_bytes_output *)hl_gc_alloc_finalizer(sizeof(realtime_bytes_output));
	output->finalize = realtime_bytes_output_finalize;
	output->data = NULL;
	output->length = 0;
	output->capacity = 0;
	output->big_endian = true;
	return output;
}
HL_PRIM bool HL_NAME(__bytes_output_big_endian)( realtime_bytes_output *output ) { return output->big_endian; }
HL_PRIM void HL_NAME(__bytes_output_set_big_endian)( realtime_bytes_output *output, bool value ) { output->big_endian = value; }
HL_PRIM void HL_NAME(__bytes_output_write_byte)( realtime_bytes_output *output, int value ) {
	realtime_bytes_output_reserve(output, 1);
	output->data[output->length++] = (vbyte)value;
}
HL_PRIM void HL_NAME(__bytes_output_write_i32)( realtime_bytes_output *output, int value ) {
	realtime_bytes_output_reserve(output, 4);
	for( int i = 0; i < 4; i++ ) output->data[output->length + i] = (vbyte)(value >> (output->big_endian ? 24 - i * 8 : i * 8));
	output->length += 4;
}
HL_PRIM void HL_NAME(__bytes_output_write_f64)( realtime_bytes_output *output, double value ) {
	union { double value; vbyte bytes[8]; } encoded;
	encoded.value = value;
	realtime_bytes_output_reserve(output, 8);
	for( int i = 0; i < 8; i++ ) output->data[output->length + i] = encoded.bytes[output->big_endian ? 7 - i : i];
	output->length += 8;
}
HL_PRIM void HL_NAME(__bytes_output_write_string)( realtime_bytes_output *output, vbyte *value ) {
	const char *utf8 = value == NULL ? "" : hl_to_utf8((const uchar *)value);
	int length = (int)strlen(utf8);
	realtime_bytes_output_reserve(output, length);
	if( length > 0 ) memcpy(output->data + output->length, utf8, (size_t)length);
	output->length += length;
}
HL_PRIM void HL_NAME(__bytes_output_write)( realtime_bytes_output *output, realtime_bytes *bytes ) {
	realtime_bytes_output_reserve(output, bytes->length);
	if( bytes->length > 0 ) memcpy(output->data + output->length, bytes->data, (size_t)bytes->length);
	output->length += bytes->length;
}
HL_PRIM realtime_bytes *HL_NAME(__bytes_output_get_bytes)( realtime_bytes_output *output ) {
	realtime_bytes *bytes = realtime_bytes_make(output->length);
	if( output->length > 0 ) memcpy(bytes->data, output->data, (size_t)output->length);
	return bytes;
}
HL_PRIM void HL_NAME(__file_save_bytes)( vbyte *path, realtime_bytes *bytes ) {
	FILE *file = fopen(hl_to_utf8((const uchar *)path), "wb");
	if( file == NULL ) hl_error("Could not open output file");
	if( bytes->length > 0 && fwrite(bytes->data, 1, (size_t)bytes->length, file) != (size_t)bytes->length ) {
		fclose(file);
		hl_error("Could not write output file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close output file");
}

HL_PRIM bool HL_NAME(__exception_matches)( vdynamic *value, hl_type *type ) {
	return value != NULL && type != NULL && hl_safe_cast(value->t,type);
}

static vbyte **array_int_storage(vobj *object) {
	hl_runtime_obj *runtime = hl_get_obj_rt(object->t);
	return (vbyte **)((char *)object + runtime->fields_indexes[0]);
}

static int *array_int_length(vobj *object) {
	hl_runtime_obj *runtime = hl_get_obj_rt(object->t);
	return (int *)((char *)object + runtime->fields_indexes[1]);
}

HL_PRIM varray *HL_NAME(array_int_alloc)( int length ) {
	return hl_alloc_array(&hlt_i32, length);
}

HL_PRIM varray *HL_NAME(__array_alloc_i32)( int length ) {
	return hl_alloc_array(&hlt_i32, length);
}

HL_PRIM varray *HL_NAME(__array_alloc_f64)( int length ) {
	return hl_alloc_array(&hlt_f64, length);
}

HL_PRIM varray *HL_NAME(__array_alloc_bytes)( int length ) {
	return hl_alloc_array(&hlt_bytes, length);
}

HL_PRIM varray *HL_NAME(__array_alloc_bool)( int length ) {
	return hl_alloc_array(&hlt_bool, length);
}

HL_PRIM varray *HL_NAME(__array_alloc_ref)( int length ) {
	return hl_alloc_array(&hlt_dyn, length);
}

static varray *realtime_array_copy(varray *array) {
	varray *copy = hl_alloc_array(array->at, array->size);
	if (array->size > 0)
		memcpy(hl_aptr(copy, vbyte), hl_aptr(array, vbyte), (size_t)array->size * hl_type_size(array->at));
	return copy;
}

static varray *realtime_array_concat(varray *left, varray *right) {
	if (left->at != right->at)
		hl_error("Array.concat element type mismatch");
	varray *result = hl_alloc_array(left->at, left->size + right->size);
	int stride = hl_type_size(left->at);
	if (left->size > 0)
		memcpy(hl_aptr(result, vbyte), hl_aptr(left, vbyte), (size_t)left->size * stride);
	if (right->size > 0)
		memcpy(hl_aptr(result, vbyte) + left->size * stride, hl_aptr(right, vbyte), (size_t)right->size * stride);
	return result;
}

static int realtime_array_index(varray *array, int index) {
	if (index < 0) return 0;
	if (index > array->size) return array->size;
	return index;
}

static void realtime_array_slice_bounds(varray *array, int *start, int *end) {
	int normalizedStart = *start < 0 ? array->size + *start : *start;
	int normalizedEnd = *end < 0 ? array->size + *end : *end;
	*start = realtime_array_index(array, normalizedStart);
	*end = realtime_array_index(array, normalizedEnd);
	if (*end < *start) *end = *start;
}

static varray *realtime_array_slice(varray *array, int start, int end) {
	realtime_array_slice_bounds(array, &start, &end);
	varray *result = hl_alloc_array(array->at, end - start);
	int stride = hl_type_size(array->at);
	if (end > start)
		memcpy(hl_aptr(result, vbyte), hl_aptr(array, vbyte) + start * stride, (size_t)(end - start) * stride);
	return result;
}

static bool realtime_bytes_equal(vbyte *left, vbyte *right) {
	int leftLength = left == NULL ? 0 : (int)ustrlen((const uchar *)left);
	int rightLength = right == NULL ? 0 : (int)ustrlen((const uchar *)right);
	return leftLength == rightLength
		&& (leftLength == 0 || memcmp(left, right, leftLength * (int)sizeof(uchar)) == 0);
}

static varray *realtime_typed_values(varray *dynamicValues, hl_type *valueType) {
	varray *result = hl_alloc_array(valueType, dynamicValues->size);
	vdynamic **source = hl_aptr(dynamicValues, vdynamic *);
	int stride = hl_type_size(valueType);
	for (int i = 0; i < dynamicValues->size; i++)
		hl_write_dyn(hl_aptr(result, vbyte) + i * stride, valueType, source[i], false);
	return result;
}

static varray *realtime_ref_values(varray *dynamicValues) {
	varray *result = hl_alloc_array(&hlt_dyn, dynamicValues->size);
	vdynamic **source = hl_aptr(dynamicValues, vdynamic *);
	void **target = hl_aptr(result, void *);
	for (int i = 0; i < dynamicValues->size; i++)
		target[i] = source[i];
	return result;
}

#define DEFINE_ARRAY_COPY(SUFFIX) \
HL_PRIM varray *HL_NAME(__array_copy_##SUFFIX)( varray *array ) { return realtime_array_copy(array); } \
HL_PRIM varray *HL_NAME(__array_concat_##SUFFIX)( varray *left, varray *right ) { return realtime_array_concat(left, right); } \
HL_PRIM varray *HL_NAME(__array_slice_##SUFFIX)( varray *array, int start, int end ) { return realtime_array_slice(array, start, end); }

DEFINE_ARRAY_COPY(i32)
DEFINE_ARRAY_COPY(f64)
DEFINE_ARRAY_COPY(bytes)
DEFINE_ARRAY_COPY(bool)
DEFINE_ARRAY_COPY(ref)

#undef DEFINE_ARRAY_COPY

#define DEFINE_ARRAY_INDEX_OF(SUFFIX, VALUE_TYPE, EQUALS) \
HL_PRIM int HL_NAME(__array_index_of_##SUFFIX)( varray *array, VALUE_TYPE value ) { \
	VALUE_TYPE *values = hl_aptr(array, VALUE_TYPE); \
	for (int i = 0; i < array->size; i++) if (EQUALS) return i; \
	return -1; \
}

DEFINE_ARRAY_INDEX_OF(i32, int, values[i] == value)
DEFINE_ARRAY_INDEX_OF(f64, double, values[i] == value)
DEFINE_ARRAY_INDEX_OF(bool, bool, values[i] == value)
DEFINE_ARRAY_INDEX_OF(bytes, vbyte *, realtime_bytes_equal(values[i], value))

#undef DEFINE_ARRAY_INDEX_OF

#define DEFINE_ARRAY_MUTATION(SUFFIX, VALUE_TYPE) \
HL_PRIM varray *HL_NAME(__array_push_##SUFFIX)( varray *array, VALUE_TYPE value ) { \
	if (array->size >= array->capacity) \
		hl_array_reserve(array, array->size + 1); \
	array->size++; \
	((VALUE_TYPE *)hl_aptr(array, vbyte))[array->size - 1] = value; \
	return array; \
} \
HL_PRIM VALUE_TYPE HL_NAME(__array_pop_##SUFFIX)( varray *array ) { \
	if (array->size <= 0) \
		hl_error("Array.pop on an empty array"); \
	VALUE_TYPE value = ((VALUE_TYPE *)hl_aptr(array, vbyte))[array->size - 1]; \
	array->size--; \
	memset(hl_aptr(array, vbyte) + array->size * hl_type_size(array->at), 0, hl_type_size(array->at)); \
	return value; \
}

DEFINE_ARRAY_MUTATION(i32, int)
DEFINE_ARRAY_MUTATION(f64, double)
DEFINE_ARRAY_MUTATION(bytes, vbyte *)
DEFINE_ARRAY_MUTATION(bool, bool)
DEFINE_ARRAY_MUTATION(ref, vdynamic *)

#undef DEFINE_ARRAY_MUTATION

HL_PRIM realtime_string_map *HL_NAME(__map_string_i32_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_i32_set)( realtime_string_map *map, vbyte *key, int value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_i32);
	dynamic->v.i = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_i32_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM int HL_NAME(__map_string_i32_get)( realtime_string_map *map, vbyte *key ) {
	vdynamic *dynamic = hl_hbget(map, (uchar *)key);
	return dynamic == NULL ? 0 : dynamic->v.i;
}

HL_PRIM realtime_string_map *HL_NAME(__map_string_bool_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_bool_set)( realtime_string_map *map, vbyte *key, bool value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_bool);
	dynamic->v.b = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_bool_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM bool HL_NAME(__map_string_bool_get)( realtime_string_map *map, vbyte *key ) {
	vdynamic *dynamic = hl_hbget(map, (uchar *)key);
	return dynamic == NULL ? false : dynamic->v.b;
}

HL_PRIM realtime_string_map *HL_NAME(__map_string_f64_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_f64_set)( realtime_string_map *map, vbyte *key, double value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_f64);
	dynamic->v.d = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_f64_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM double HL_NAME(__map_string_f64_get)( realtime_string_map *map, vbyte *key ) {
	vdynamic *dynamic = hl_hbget(map, (uchar *)key);
	return dynamic == NULL ? 0.0 : dynamic->v.d;
}

HL_PRIM realtime_string_map *HL_NAME(__map_string_bytes_alloc)( void ) {
	return hl_hballoc();
}

HL_PRIM void HL_NAME(__map_string_bytes_set)( realtime_string_map *map, vbyte *key, vbyte *value ) {
	vdynamic *dynamic = hl_alloc_dynamic(&hlt_bytes);
	dynamic->v.bytes = value;
	hl_hbset(map, (uchar *)key, dynamic);
}

HL_PRIM bool HL_NAME(__map_string_bytes_exists)( realtime_string_map *map, vbyte *key ) {
	return hl_hbexists(map, (uchar *)key);
}

HL_PRIM vbyte *HL_NAME(__map_string_bytes_get)( realtime_string_map *map, vbyte *key ) {
	vdynamic *dynamic = hl_hbget(map, (uchar *)key);
	return dynamic == NULL ? NULL : dynamic->v.bytes;
}

HL_PRIM varray *HL_NAME(__map_string_i32_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_bool_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_f64_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_bytes_keys)( realtime_string_map *map ) { return hl_hbkeys(map); }
HL_PRIM varray *HL_NAME(__map_string_i32_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_i32); }
HL_PRIM varray *HL_NAME(__map_string_bool_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_bool); }
HL_PRIM varray *HL_NAME(__map_string_f64_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_f64); }
HL_PRIM varray *HL_NAME(__map_string_bytes_values)( realtime_string_map *map ) { return realtime_typed_values(hl_hbvalues(map), &hlt_bytes); }
HL_PRIM bool HL_NAME(__map_string_i32_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_bool_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_f64_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM bool HL_NAME(__map_string_bytes_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); }
HL_PRIM void HL_NAME(__map_string_i32_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_bool_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_f64_clear)( realtime_string_map *map ) { hl_hbclear(map); }
HL_PRIM void HL_NAME(__map_string_bytes_clear)( realtime_string_map *map ) { hl_hbclear(map); }

#define DEFINE_STRING_MAP_SIZE(SUFFIX) \
HL_PRIM int HL_NAME(__map_string_##SUFFIX##_size)( realtime_string_map *map ) { return hl_hbsize(map); }

DEFINE_STRING_MAP_SIZE(i32)
DEFINE_STRING_MAP_SIZE(bool)
DEFINE_STRING_MAP_SIZE(f64)
DEFINE_STRING_MAP_SIZE(bytes)

#undef DEFINE_STRING_MAP_SIZE

#define DEFINE_STRING_REF_MAP() \
HL_PRIM realtime_string_map *HL_NAME(__map_string_ref_alloc)( void ) { return hl_hballoc(); } \
HL_PRIM void HL_NAME(__map_string_ref_set)( realtime_string_map *map, vbyte *key, void *value ) { \
	hl_hbset(map, (uchar *)key, (vdynamic *)value); \
} \
HL_PRIM bool HL_NAME(__map_string_ref_exists)( realtime_string_map *map, vbyte *key ) { return hl_hbexists(map, (uchar *)key); } \
HL_PRIM vdynamic *HL_NAME(__map_string_ref_get)( realtime_string_map *map, vbyte *key ) { \
	vdynamic *dynamic = hl_hbget(map, (uchar *)key); \
	return dynamic; \
} \
HL_PRIM varray *HL_NAME(__map_string_ref_keys)( realtime_string_map *map ) { return hl_hbkeys(map); } \
HL_PRIM varray *HL_NAME(__map_string_ref_values)( realtime_string_map *map ) { return realtime_ref_values(hl_hbvalues(map)); } \
HL_PRIM bool HL_NAME(__map_string_ref_remove)( realtime_string_map *map, vbyte *key ) { return hl_hbremove(map, (uchar *)key); } \
HL_PRIM void HL_NAME(__map_string_ref_clear)( realtime_string_map *map ) { hl_hbclear(map); } \
HL_PRIM int HL_NAME(__map_string_ref_size)( realtime_string_map *map ) { return hl_hbsize(map); }

DEFINE_STRING_REF_MAP()

#undef DEFINE_STRING_REF_MAP

#define DEFINE_INT_MAP(SUFFIX, VALUE_TYPE, VALUE_FIELD, VALUE_HLTYPE, DEFAULT_VALUE) \
HL_PRIM realtime_int_map *HL_NAME(__map_int_##SUFFIX##_alloc)( void ) { return hl_hialloc(); } \
HL_PRIM void HL_NAME(__map_int_##SUFFIX##_set)( realtime_int_map *map, int key, VALUE_TYPE value ) { \
	vdynamic *dynamic = hl_alloc_dynamic(&VALUE_HLTYPE); \
	dynamic->v.VALUE_FIELD = value; \
	hl_hiset(map, key, dynamic); \
} \
HL_PRIM bool HL_NAME(__map_int_##SUFFIX##_exists)( realtime_int_map *map, int key ) { return hl_hiexists(map, key); } \
HL_PRIM VALUE_TYPE HL_NAME(__map_int_##SUFFIX##_get)( realtime_int_map *map, int key ) { \
	vdynamic *dynamic = hl_higet(map, key); \
	return dynamic == NULL ? DEFAULT_VALUE : dynamic->v.VALUE_FIELD; \
}

DEFINE_INT_MAP(i32, int, i, hlt_i32, 0)
DEFINE_INT_MAP(bool, bool, b, hlt_bool, false)
DEFINE_INT_MAP(f64, double, d, hlt_f64, 0.0)
DEFINE_INT_MAP(bytes, vbyte *, bytes, hlt_bytes, NULL)

HL_PRIM varray *HL_NAME(__map_int_i32_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_bool_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_f64_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_bytes_keys)( realtime_int_map *map ) { return hl_hikeys(map); }
HL_PRIM varray *HL_NAME(__map_int_i32_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_i32); }
HL_PRIM varray *HL_NAME(__map_int_bool_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_bool); }
HL_PRIM varray *HL_NAME(__map_int_f64_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_f64); }
HL_PRIM varray *HL_NAME(__map_int_bytes_values)( realtime_int_map *map ) { return realtime_typed_values(hl_hivalues(map), &hlt_bytes); }
HL_PRIM bool HL_NAME(__map_int_i32_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_bool_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_f64_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM bool HL_NAME(__map_int_bytes_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); }
HL_PRIM void HL_NAME(__map_int_i32_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_bool_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_f64_clear)( realtime_int_map *map ) { hl_hiclear(map); }
HL_PRIM void HL_NAME(__map_int_bytes_clear)( realtime_int_map *map ) { hl_hiclear(map); }

#define DEFINE_INT_MAP_SIZE(SUFFIX) \
HL_PRIM int HL_NAME(__map_int_##SUFFIX##_size)( realtime_int_map *map ) { return hl_hisize(map); }

DEFINE_INT_MAP_SIZE(i32)
DEFINE_INT_MAP_SIZE(bool)
DEFINE_INT_MAP_SIZE(f64)
DEFINE_INT_MAP_SIZE(bytes)

#undef DEFINE_INT_MAP_SIZE

#define DEFINE_INT_REF_MAP() \
HL_PRIM realtime_int_map *HL_NAME(__map_int_ref_alloc)( void ) { return hl_hialloc(); } \
HL_PRIM void HL_NAME(__map_int_ref_set)( realtime_int_map *map, int key, void *value ) { \
	hl_hiset(map, key, (vdynamic *)value); \
} \
HL_PRIM bool HL_NAME(__map_int_ref_exists)( realtime_int_map *map, int key ) { return hl_hiexists(map, key); } \
HL_PRIM vdynamic *HL_NAME(__map_int_ref_get)( realtime_int_map *map, int key ) { \
	vdynamic *dynamic = hl_higet(map, key); \
	return dynamic; \
} \
HL_PRIM varray *HL_NAME(__map_int_ref_keys)( realtime_int_map *map ) { return hl_hikeys(map); } \
HL_PRIM varray *HL_NAME(__map_int_ref_values)( realtime_int_map *map ) { return realtime_ref_values(hl_hivalues(map)); } \
HL_PRIM bool HL_NAME(__map_int_ref_remove)( realtime_int_map *map, int key ) { return hl_hiremove(map, key); } \
HL_PRIM void HL_NAME(__map_int_ref_clear)( realtime_int_map *map ) { hl_hiclear(map); } \
HL_PRIM int HL_NAME(__map_int_ref_size)( realtime_int_map *map ) { return hl_hisize(map); }

DEFINE_INT_REF_MAP()

#undef DEFINE_INT_REF_MAP

#undef DEFINE_INT_MAP

HL_PRIM vbyte *HL_NAME(__string_concat)( vbyte *left, vbyte *right ) {
	int left_length = left == NULL ? 0 : (int)ustrlen((const uchar *)left);
	int right_length = right == NULL ? 0 : (int)ustrlen((const uchar *)right);
	vbyte *result = hl_alloc_bytes((left_length + right_length + 1) * (int)sizeof(uchar));
	if (left_length > 0)
		memcpy(result, left, left_length * sizeof(uchar));
	if (right_length > 0)
		memcpy(result + left_length * sizeof(uchar), right, right_length * sizeof(uchar));
	((uchar *)result)[left_length + right_length] = 0;
	return result;
}

HL_PRIM int HL_NAME(__string_length)( vbyte *value ) {
	return value == NULL ? 0 : (int)ustrlen((const uchar *)value);
}

HL_PRIM bool HL_NAME(__string_equal)( vbyte *left, vbyte *right ) {
	int left_length = left == NULL ? 0 : (int)ustrlen((const uchar *)left);
	int right_length = right == NULL ? 0 : (int)ustrlen((const uchar *)right);
	return left_length == right_length
		&& (left_length == 0 || memcmp(left, right, left_length * (int)sizeof(uchar)) == 0);
}

HL_PRIM int HL_NAME(__string_index_of)( vbyte *value, vbyte *needle ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int needle_length = needle == NULL ? 0 : (int)ustrlen((const uchar *)needle);
	if( needle_length == 0 ) return 0;
	if( needle_length > value_length ) return -1;
	for( int i = 0; i <= value_length - needle_length; i++ )
		if( memcmp(value + i * sizeof(uchar), needle, needle_length * sizeof(uchar)) == 0 ) return i;
	return -1;
}

HL_PRIM int HL_NAME(__string_char_code_at)( vbyte *value, int index ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	if( index < 0 || index >= length ) return -1;
	return ((const uchar *)value)[index];
}

HL_PRIM vbyte *HL_NAME(__string_char_at)( vbyte *value, int index ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	bool present = index >= 0 && index < length;
	vbyte *result = hl_alloc_bytes((present ? 2 : 1) * (int)sizeof(uchar));
	if( present ) ((uchar *)result)[0] = ((const uchar *)value)[index];
	((uchar *)result)[present ? 1 : 0] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_from_char_code)( int code ) {
	vbyte *result = hl_alloc_bytes(2 * (int)sizeof(uchar));
	((uchar *)result)[0] = (uchar)code;
	((uchar *)result)[1] = 0;
	return result;
}

HL_PRIM int HL_NAME(__std_parse_int)( vbyte *value ) {
	return value == NULL ? 0 : (int)strtol(hl_to_utf8((const uchar *)value), NULL, 0);
}

HL_PRIM double HL_NAME(__std_parse_float)( vbyte *value ) {
	return value == NULL ? 0.0 : strtod(hl_to_utf8((const uchar *)value), NULL);
}

HL_PRIM int HL_NAME(__std_int_f64)( double value ) { return (int)value; }
HL_PRIM int HL_NAME(__std_random)( int limit ) { return limit <= 0 ? 0 : rand() % limit; }

HL_PRIM vbyte *HL_NAME(__std_string)( vdynamic *value ) {
	if( value != NULL ) switch( value->t->kind ) {
	case HOBJ:
	case HSTRUCT:
	case HARRAY:
	case HENUM:
	case HVIRTUAL:
	case HDYNOBJ:
	case HFUN:
		return (vbyte *)hl_to_string((vdynamic *)value->v.ptr);
	default:
		break;
	}
	return (vbyte *)hl_to_string(value);
}

HL_PRIM int HL_NAME(__reflect_compare)( vbyte *left, vbyte *right ) {
	if( left == NULL ) return right == NULL ? 0 : -1;
	if( right == NULL ) return 1;
	const uchar *a = (const uchar *)left, *b = (const uchar *)right;
	while( *a != 0 && *a == *b ) { a++; b++; }
	return (int)*a - (int)*b;
}

HL_PRIM bool HL_NAME(__string_starts_with)( vbyte *value, vbyte *prefix ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int prefix_length = prefix == NULL ? 0 : (int)ustrlen((const uchar *)prefix);
	return prefix_length <= value_length && memcmp(value, prefix, prefix_length * sizeof(uchar)) == 0;
}

HL_PRIM bool HL_NAME(__string_ends_with)( vbyte *value, vbyte *suffix ) {
	int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	int suffix_length = suffix == NULL ? 0 : (int)ustrlen((const uchar *)suffix);
	return suffix_length <= value_length
		&& memcmp(value + (value_length - suffix_length) * sizeof(uchar), suffix, suffix_length * sizeof(uchar)) == 0;
}

HL_PRIM vbyte *HL_NAME(__file_get_content)( vbyte *path ) {
	FILE *file = fopen(hl_to_utf8((const uchar *)path), "rb");
	if( file == NULL ) hl_error("Could not open source file");
	if( fseek(file, 0, SEEK_END) != 0 ) {
		fclose(file);
		hl_error("Could not seek source file");
	}
	long byte_length = ftell(file);
	if( byte_length < 0 || fseek(file, 0, SEEK_SET) != 0 ) {
		fclose(file);
		hl_error("Could not measure source file");
	}
	char *utf8 = (char *)malloc((size_t)byte_length + 1);
	if( utf8 == NULL ) {
		fclose(file);
		hl_error("Could not allocate source buffer");
	}
	if( fread(utf8, 1, (size_t)byte_length, file) != (size_t)byte_length ) {
		free(utf8);
		fclose(file);
		hl_error("Could not read source file");
	}
	fclose(file);
	utf8[byte_length] = 0;
	int length = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, length, utf8);
	result[length] = 0;
	free(utf8);
	return (vbyte *)result;
}

HL_PRIM vbyte *HL_NAME(__array_join_bytes)( varray *array, vbyte *separator ) {
	int separator_length = separator == NULL ? 0 : (int)ustrlen((const uchar *)separator);
	int length = separator_length * (array->size > 0 ? array->size - 1 : 0);
	for( int i = 0; i < array->size; i++ ) {
		vbyte *value = hl_aptr(array,vbyte*)[i];
		if( value != NULL ) length += (int)ustrlen((const uchar *)value);
	}
	vbyte *result = hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	uchar *output = (uchar *)result;
	int offset = 0;
	for( int i = 0; i < array->size; i++ ) {
		if( i > 0 && separator_length > 0 ) {
			memcpy(output + offset, separator, separator_length * sizeof(uchar));
			offset += separator_length;
		}
		vbyte *value = hl_aptr(array,vbyte*)[i];
		int value_length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
		if( value_length > 0 ) {
			memcpy(output + offset, value, value_length * sizeof(uchar));
			offset += value_length;
		}
	}
	output[offset] = 0;
	return result;
}

HL_PRIM vbyte *HL_NAME(__string_substring)( vbyte *value, int start, int end ) {
	int length = value == NULL ? 0 : (int)ustrlen((const uchar *)value);
	if( start < 0 ) start = 0;
	if( end < start ) end = start;
	if( start > length ) start = length;
	if( end > length ) end = length;
	int count = end - start;
	vbyte *result = hl_alloc_bytes((count + 1) * (int)sizeof(uchar));
	if( count > 0 )
		memcpy(result, value + start * sizeof(uchar), count * sizeof(uchar));
	((uchar *)result)[count] = 0;
	return result;
}

HL_PRIM void HL_NAME(array_int_init)( vobj *object ) {
	*array_int_storage(object) = hl_alloc_bytes(0);
	*array_int_length(object) = 0;
}

HL_PRIM void HL_NAME(array_int_push)( vobj *object, int value ) {
	int length = *array_int_length(object);
	vbyte *old_storage = *array_int_storage(object);
	vbyte *new_storage = hl_alloc_bytes((length + 1) * (int)sizeof(int));
	if (length > 0)
		memcpy(new_storage, old_storage, length * sizeof(int));
	((int *)new_storage)[length] = value;
	*array_int_storage(object) = new_storage;
	*array_int_length(object) = length + 1;
}

HL_PRIM int HL_NAME(array_int_get)( vobj *object, int index ) {
	int length = *array_int_length(object);
	if (index < 0 || index >= length)
		hl_error("IntArray index out of bounds");
	return ((int *)*array_int_storage(object))[index];
}

HL_PRIM int HL_NAME(array_int_length)( vobj *object ) {
	return *array_int_length(object);
}

HL_PRIM hl_runtime_module *HL_NAME(load)( vbyte *bytes, int length, vbyte *identity, int identity_length ) {
	hl_runtime_module *runtime = NULL;
	return hl_runtime_module_load(bytes,length,identity,identity_length,&runtime) == HL_RUNTIME_OK ? runtime : NULL;
}

HL_PRIM int HL_NAME(call_i32)( hl_runtime_module *runtime, int stable_id ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_i32(runtime,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime function call (status %d, stable ID %d)",status,stable_id);
	return result;
}

HL_PRIM void HL_NAME(call_void)( hl_runtime_module *runtime, int stable_id ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_void(runtime,stable_id,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime void function call (status %d)",status);
}

HL_PRIM vbyte *HL_NAME(call_bytes)( hl_runtime_module *runtime, int stable_id ) {
	vbyte *result = NULL;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes(runtime,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime string function call (status %d)",status);
	return result;
}

HL_PRIM void HL_NAME(call_bytes1)( hl_runtime_module *runtime, int stable_id, vbyte *argument ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes1(runtime,stable_id,argument,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime string argument function call (status %d)",status);
}

HL_PRIM vdynamic *HL_NAME(call_closure)( hl_runtime_module *runtime, int stable_id ) {
	vclosure *result = NULL;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_closure(runtime,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime closure function call (status %d)",status);
	return (vdynamic*)result;
}

HL_PRIM int HL_NAME(call_closure_i32)( hl_runtime_module *runtime, vclosure *closure ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_retained_closure_i32(runtime,closure,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid retained runtime closure (status %d)",status);
	return result;
}

HL_PRIM vdynamic *HL_NAME(call_object)( hl_runtime_module *runtime, int stable_id ) {
	vdynamic *result = NULL, *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_object(runtime,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime object function call (status %d)",status);
	return result;
}

HL_PRIM int HL_NAME(call_i32_object)( hl_runtime_module *runtime, int stable_id, vdynamic *argument ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_i32_object(runtime,stable_id,argument,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime object argument call (status %d)",status);
	return result;
}

HL_PRIM int HL_NAME(validate_call)( hl_runtime_module *runtime, int stable_id, int shape ) {
	return hl_runtime_module_validate_call(runtime,stable_id,shape);
}

HL_PRIM int HL_NAME(patch)( hl_runtime_module *runtime, vbyte *bytes, int length ) {
	return hl_runtime_module_apply_hlp(runtime,bytes,length);
}

HL_PRIM int HL_NAME(allocation_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_allocation_count(runtime);
}

HL_PRIM int HL_NAME(patch_jit_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_jit_count(runtime);
}

HL_PRIM int HL_NAME(retired_allocation_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_retired_allocation_count(runtime);
}

HL_PRIM int HL_NAME(type_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_type_count(runtime);
}

HL_PRIM int HL_NAME(type_capacity)( hl_runtime_module *runtime ) {
	return hl_runtime_module_type_capacity(runtime);
}

HL_PRIM int HL_NAME(live_allocation_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_live_allocation_count(runtime);
}

HL_PRIM int HL_NAME(native_root_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_native_root_count(runtime);
}

HL_PRIM int HL_NAME(revision)( hl_runtime_module *runtime ) {
	return hl_runtime_module_revision(runtime);
}

HL_PRIM void HL_NAME(set_patch_failure_stage)( hl_runtime_module *runtime, int stage ) {
	hl_runtime_module_set_patch_failure_stage(runtime,stage);
}

HL_PRIM void HL_NAME(dispose)( hl_runtime_module *runtime ) {
	hl_runtime_module_release(runtime);
}

HL_PRIM int HL_NAME(inspect_patch)( vbyte *bytes, int length ) {
	int base_revision, revision, function_count;
	hl_runtime_status status = hl_runtime_hlp_summary(bytes,length,&base_revision,&revision,&function_count);
	if( status != HL_RUNTIME_OK || base_revision > 0x3FF || revision > 0x3FF || function_count > 0xFFF ) return -1;
	return (base_revision << 22) | (revision << 12) | function_count;
}

DEFINE_PRIM(_ABSTRACT(realtime_module),load,_BYTES _I32 _BYTES _I32);
DEFINE_PRIM(_I32,call_i32,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_VOID,call_void,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_BYTES,call_bytes,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_VOID,call_bytes1,_ABSTRACT(realtime_module) _I32 _BYTES);
DEFINE_PRIM(_DYN,call_closure,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_I32,call_closure_i32,_ABSTRACT(realtime_module) _DYN);
DEFINE_PRIM(_DYN,call_object,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_I32,call_i32_object,_ABSTRACT(realtime_module) _I32 _DYN);
DEFINE_PRIM(_I32,validate_call,_ABSTRACT(realtime_module) _I32 _I32);
DEFINE_PRIM(_I32,patch,_ABSTRACT(realtime_module) _BYTES _I32);
DEFINE_PRIM(_I32,allocation_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,patch_jit_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,retired_allocation_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,type_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,type_capacity,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,live_allocation_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,native_root_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,revision,_ABSTRACT(realtime_module));
DEFINE_PRIM(_VOID,set_patch_failure_stage,_ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_VOID,dispose,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,inspect_patch,_BYTES _I32);
DEFINE_PRIM(_VOID,array_int_init,_OBJ(_BYTES _I32));
DEFINE_PRIM(_VOID,array_int_push,_OBJ(_BYTES _I32) _I32);
DEFINE_PRIM(_I32,array_int_get,_OBJ(_BYTES _I32) _I32);
DEFINE_PRIM(_I32,array_int_length,_OBJ(_BYTES _I32));
DEFINE_PRIM(_ARR,array_int_alloc,_I32);
DEFINE_PRIM(_ARR,__array_alloc_i32,_I32);
DEFINE_PRIM(_ARR,__array_alloc_f64,_I32);
DEFINE_PRIM(_ARR,__array_alloc_bytes,_I32);
DEFINE_PRIM(_ARR,__array_alloc_bool,_I32);
DEFINE_PRIM(_ARR,__array_alloc_ref,_I32);
DEFINE_PRIM(_ARR,__array_copy_i32,_ARR);
DEFINE_PRIM(_ARR,__array_copy_f64,_ARR);
DEFINE_PRIM(_ARR,__array_copy_bytes,_ARR);
DEFINE_PRIM(_ARR,__array_copy_bool,_ARR);
DEFINE_PRIM(_ARR,__array_copy_ref,_ARR);
DEFINE_PRIM(_ARR,__array_concat_i32,_ARR _ARR);
DEFINE_PRIM(_ARR,__array_concat_f64,_ARR _ARR);
DEFINE_PRIM(_ARR,__array_concat_bytes,_ARR _ARR);
DEFINE_PRIM(_ARR,__array_concat_bool,_ARR _ARR);
DEFINE_PRIM(_ARR,__array_concat_ref,_ARR _ARR);
DEFINE_PRIM(_ARR,__array_slice_i32,_ARR _I32 _I32);
DEFINE_PRIM(_ARR,__array_slice_f64,_ARR _I32 _I32);
DEFINE_PRIM(_ARR,__array_slice_bytes,_ARR _I32 _I32);
DEFINE_PRIM(_ARR,__array_slice_bool,_ARR _I32 _I32);
DEFINE_PRIM(_ARR,__array_slice_ref,_ARR _I32 _I32);
DEFINE_PRIM(_I32,__array_index_of_i32,_ARR _I32);
DEFINE_PRIM(_I32,__array_index_of_f64,_ARR _F64);
DEFINE_PRIM(_I32,__array_index_of_bytes,_ARR _BYTES);
DEFINE_PRIM(_I32,__array_index_of_bool,_ARR _BOOL);
DEFINE_PRIM(_ARR,__array_push_i32,_ARR _I32);
DEFINE_PRIM(_I32,__array_pop_i32,_ARR);
DEFINE_PRIM(_ARR,__array_push_f64,_ARR _F64);
DEFINE_PRIM(_F64,__array_pop_f64,_ARR);
DEFINE_PRIM(_ARR,__array_push_bytes,_ARR _BYTES);
DEFINE_PRIM(_BYTES,__array_pop_bytes,_ARR);
DEFINE_PRIM(_ARR,__array_push_bool,_ARR _BOOL);
DEFINE_PRIM(_BOOL,__array_pop_bool,_ARR);
DEFINE_PRIM(_ARR,__array_push_ref,_ARR _DYN);
DEFINE_PRIM(_DYN,__array_pop_ref,_ARR);
DEFINE_PRIM(_ABSTRACT(map_string_i32),__map_string_i32_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_string_i32_set,_ABSTRACT(map_string_i32) _BYTES _I32);
DEFINE_PRIM(_BOOL,__map_string_i32_exists,_ABSTRACT(map_string_i32) _BYTES);
DEFINE_PRIM(_I32,__map_string_i32_get,_ABSTRACT(map_string_i32) _BYTES);
DEFINE_PRIM(_ABSTRACT(map_string_bool),__map_string_bool_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_string_bool_set,_ABSTRACT(map_string_bool) _BYTES _BOOL);
DEFINE_PRIM(_BOOL,__map_string_bool_exists,_ABSTRACT(map_string_bool) _BYTES);
DEFINE_PRIM(_BOOL,__map_string_bool_get,_ABSTRACT(map_string_bool) _BYTES);
DEFINE_PRIM(_ABSTRACT(map_string_f64),__map_string_f64_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_string_f64_set,_ABSTRACT(map_string_f64) _BYTES _F64);
DEFINE_PRIM(_BOOL,__map_string_f64_exists,_ABSTRACT(map_string_f64) _BYTES);
DEFINE_PRIM(_F64,__map_string_f64_get,_ABSTRACT(map_string_f64) _BYTES);
DEFINE_PRIM(_ABSTRACT(map_string_bytes),__map_string_bytes_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_string_bytes_set,_ABSTRACT(map_string_bytes) _BYTES _BYTES);
DEFINE_PRIM(_BOOL,__map_string_bytes_exists,_ABSTRACT(map_string_bytes) _BYTES);
DEFINE_PRIM(_BYTES,__map_string_bytes_get,_ABSTRACT(map_string_bytes) _BYTES);
DEFINE_PRIM(_ARR,__map_string_i32_keys,_ABSTRACT(map_string_i32));
DEFINE_PRIM(_ARR,__map_string_bool_keys,_ABSTRACT(map_string_bool));
DEFINE_PRIM(_ARR,__map_string_f64_keys,_ABSTRACT(map_string_f64));
DEFINE_PRIM(_ARR,__map_string_bytes_keys,_ABSTRACT(map_string_bytes));
DEFINE_PRIM(_ARR,__map_string_i32_values,_ABSTRACT(map_string_i32));
DEFINE_PRIM(_ARR,__map_string_bool_values,_ABSTRACT(map_string_bool));
DEFINE_PRIM(_ARR,__map_string_f64_values,_ABSTRACT(map_string_f64));
DEFINE_PRIM(_ARR,__map_string_bytes_values,_ABSTRACT(map_string_bytes));
DEFINE_PRIM(_BOOL,__map_string_i32_remove,_ABSTRACT(map_string_i32) _BYTES);
DEFINE_PRIM(_BOOL,__map_string_bool_remove,_ABSTRACT(map_string_bool) _BYTES);
DEFINE_PRIM(_BOOL,__map_string_f64_remove,_ABSTRACT(map_string_f64) _BYTES);
DEFINE_PRIM(_BOOL,__map_string_bytes_remove,_ABSTRACT(map_string_bytes) _BYTES);
DEFINE_PRIM(_VOID,__map_string_i32_clear,_ABSTRACT(map_string_i32));
DEFINE_PRIM(_VOID,__map_string_bool_clear,_ABSTRACT(map_string_bool));
DEFINE_PRIM(_VOID,__map_string_f64_clear,_ABSTRACT(map_string_f64));
DEFINE_PRIM(_VOID,__map_string_bytes_clear,_ABSTRACT(map_string_bytes));
DEFINE_PRIM(_I32,__map_string_i32_size,_ABSTRACT(map_string_i32));
DEFINE_PRIM(_I32,__map_string_bool_size,_ABSTRACT(map_string_bool));
DEFINE_PRIM(_I32,__map_string_f64_size,_ABSTRACT(map_string_f64));
DEFINE_PRIM(_I32,__map_string_bytes_size,_ABSTRACT(map_string_bytes));
DEFINE_PRIM(_ABSTRACT(map_string_ref),__map_string_ref_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_string_ref_set,_ABSTRACT(map_string_ref) _BYTES _DYN);
DEFINE_PRIM(_BOOL,__map_string_ref_exists,_ABSTRACT(map_string_ref) _BYTES);
DEFINE_PRIM(_DYN,__map_string_ref_get,_ABSTRACT(map_string_ref) _BYTES);
DEFINE_PRIM(_ARR,__map_string_ref_keys,_ABSTRACT(map_string_ref));
DEFINE_PRIM(_ARR,__map_string_ref_values,_ABSTRACT(map_string_ref));
DEFINE_PRIM(_BOOL,__map_string_ref_remove,_ABSTRACT(map_string_ref) _BYTES);
DEFINE_PRIM(_VOID,__map_string_ref_clear,_ABSTRACT(map_string_ref));
DEFINE_PRIM(_I32,__map_string_ref_size,_ABSTRACT(map_string_ref));
DEFINE_PRIM(_ABSTRACT(map_int_i32),__map_int_i32_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_int_i32_set,_ABSTRACT(map_int_i32) _I32 _I32);
DEFINE_PRIM(_BOOL,__map_int_i32_exists,_ABSTRACT(map_int_i32) _I32);
DEFINE_PRIM(_I32,__map_int_i32_get,_ABSTRACT(map_int_i32) _I32);
DEFINE_PRIM(_ABSTRACT(map_int_bool),__map_int_bool_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_int_bool_set,_ABSTRACT(map_int_bool) _I32 _BOOL);
DEFINE_PRIM(_BOOL,__map_int_bool_exists,_ABSTRACT(map_int_bool) _I32);
DEFINE_PRIM(_BOOL,__map_int_bool_get,_ABSTRACT(map_int_bool) _I32);
DEFINE_PRIM(_ABSTRACT(map_int_f64),__map_int_f64_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_int_f64_set,_ABSTRACT(map_int_f64) _I32 _F64);
DEFINE_PRIM(_BOOL,__map_int_f64_exists,_ABSTRACT(map_int_f64) _I32);
DEFINE_PRIM(_F64,__map_int_f64_get,_ABSTRACT(map_int_f64) _I32);
DEFINE_PRIM(_ABSTRACT(map_int_bytes),__map_int_bytes_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_int_bytes_set,_ABSTRACT(map_int_bytes) _I32 _BYTES);
DEFINE_PRIM(_BOOL,__map_int_bytes_exists,_ABSTRACT(map_int_bytes) _I32);
DEFINE_PRIM(_BYTES,__map_int_bytes_get,_ABSTRACT(map_int_bytes) _I32);
DEFINE_PRIM(_ARR,__map_int_i32_keys,_ABSTRACT(map_int_i32));
DEFINE_PRIM(_ARR,__map_int_bool_keys,_ABSTRACT(map_int_bool));
DEFINE_PRIM(_ARR,__map_int_f64_keys,_ABSTRACT(map_int_f64));
DEFINE_PRIM(_ARR,__map_int_bytes_keys,_ABSTRACT(map_int_bytes));
DEFINE_PRIM(_ARR,__map_int_i32_values,_ABSTRACT(map_int_i32));
DEFINE_PRIM(_ARR,__map_int_bool_values,_ABSTRACT(map_int_bool));
DEFINE_PRIM(_ARR,__map_int_f64_values,_ABSTRACT(map_int_f64));
DEFINE_PRIM(_ARR,__map_int_bytes_values,_ABSTRACT(map_int_bytes));
DEFINE_PRIM(_BOOL,__map_int_i32_remove,_ABSTRACT(map_int_i32) _I32);
DEFINE_PRIM(_BOOL,__map_int_bool_remove,_ABSTRACT(map_int_bool) _I32);
DEFINE_PRIM(_BOOL,__map_int_f64_remove,_ABSTRACT(map_int_f64) _I32);
DEFINE_PRIM(_BOOL,__map_int_bytes_remove,_ABSTRACT(map_int_bytes) _I32);
DEFINE_PRIM(_VOID,__map_int_i32_clear,_ABSTRACT(map_int_i32));
DEFINE_PRIM(_VOID,__map_int_bool_clear,_ABSTRACT(map_int_bool));
DEFINE_PRIM(_VOID,__map_int_f64_clear,_ABSTRACT(map_int_f64));
DEFINE_PRIM(_VOID,__map_int_bytes_clear,_ABSTRACT(map_int_bytes));
DEFINE_PRIM(_I32,__map_int_i32_size,_ABSTRACT(map_int_i32));
DEFINE_PRIM(_I32,__map_int_bool_size,_ABSTRACT(map_int_bool));
DEFINE_PRIM(_I32,__map_int_f64_size,_ABSTRACT(map_int_f64));
DEFINE_PRIM(_I32,__map_int_bytes_size,_ABSTRACT(map_int_bytes));
DEFINE_PRIM(_ABSTRACT(map_int_ref),__map_int_ref_alloc,_NO_ARG);
DEFINE_PRIM(_VOID,__map_int_ref_set,_ABSTRACT(map_int_ref) _I32 _DYN);
DEFINE_PRIM(_BOOL,__map_int_ref_exists,_ABSTRACT(map_int_ref) _I32);
DEFINE_PRIM(_DYN,__map_int_ref_get,_ABSTRACT(map_int_ref) _I32);
DEFINE_PRIM(_ARR,__map_int_ref_keys,_ABSTRACT(map_int_ref));
DEFINE_PRIM(_ARR,__map_int_ref_values,_ABSTRACT(map_int_ref));
DEFINE_PRIM(_BOOL,__map_int_ref_remove,_ABSTRACT(map_int_ref) _I32);
DEFINE_PRIM(_VOID,__map_int_ref_clear,_ABSTRACT(map_int_ref));
DEFINE_PRIM(_I32,__map_int_ref_size,_ABSTRACT(map_int_ref));
DEFINE_PRIM(_BYTES,__string_concat,_BYTES _BYTES);
DEFINE_PRIM(_I32,__string_length,_BYTES);
DEFINE_PRIM(_BOOL,__string_equal,_BYTES _BYTES);
DEFINE_PRIM(_I32,__string_index_of,_BYTES _BYTES);
DEFINE_PRIM(_I32,__string_char_code_at,_BYTES _I32);
DEFINE_PRIM(_BYTES,__string_char_at,_BYTES _I32);
DEFINE_PRIM(_BYTES,__string_from_char_code,_I32);
DEFINE_PRIM(_I32,__std_parse_int,_BYTES);
DEFINE_PRIM(_F64,__std_parse_float,_BYTES);
DEFINE_PRIM(_I32,__std_int_f64,_F64);
DEFINE_PRIM(_I32,__std_random,_I32);
DEFINE_PRIM(_BYTES,__std_string,_DYN);
DEFINE_PRIM(_I32,__reflect_compare,_BYTES _BYTES);
DEFINE_PRIM(_BOOL,__string_starts_with,_BYTES _BYTES);
DEFINE_PRIM(_BOOL,__string_ends_with,_BYTES _BYTES);
DEFINE_PRIM(_BYTES,__file_get_content,_BYTES);
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__bytes_alloc,_I32);
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__bytes_of_string,_BYTES);
DEFINE_PRIM(_I32,__bytes_length,_ABSTRACT(realtime_bytes));
DEFINE_PRIM(_I32,__bytes_get,_ABSTRACT(realtime_bytes) _I32);
DEFINE_PRIM(_VOID,__bytes_set,_ABSTRACT(realtime_bytes) _I32 _I32);
DEFINE_PRIM(_VOID,__bytes_set_i32,_ABSTRACT(realtime_bytes) _I32 _I32);
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__bytes_sub,_ABSTRACT(realtime_bytes) _I32 _I32);
DEFINE_PRIM(_I32,__bytes_compare,_ABSTRACT(realtime_bytes) _ABSTRACT(realtime_bytes));
DEFINE_PRIM(_BYTES,__bytes_to_string,_ABSTRACT(realtime_bytes));
DEFINE_PRIM(_ARR,__sys_args,_NO_ARG);
DEFINE_PRIM(_ABSTRACT(realtime_bytes_input),__bytes_input_new,_ABSTRACT(realtime_bytes));
DEFINE_PRIM(_I32,__bytes_input_position,_ABSTRACT(realtime_bytes_input));
DEFINE_PRIM(_BOOL,__bytes_input_big_endian,_ABSTRACT(realtime_bytes_input));
DEFINE_PRIM(_VOID,__bytes_input_set_big_endian,_ABSTRACT(realtime_bytes_input) _BOOL);
DEFINE_PRIM(_I32,__bytes_input_read_byte,_ABSTRACT(realtime_bytes_input));
DEFINE_PRIM(_I32,__bytes_input_read_i32,_ABSTRACT(realtime_bytes_input));
DEFINE_PRIM(_F64,__bytes_input_read_f64,_ABSTRACT(realtime_bytes_input));
DEFINE_PRIM(_BYTES,__bytes_input_read_string,_ABSTRACT(realtime_bytes_input) _I32);
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__bytes_input_read,_ABSTRACT(realtime_bytes_input) _I32);
DEFINE_PRIM(_ABSTRACT(realtime_bytes_output),__bytes_output_new,_NO_ARG);
DEFINE_PRIM(_BOOL,__bytes_output_big_endian,_ABSTRACT(realtime_bytes_output));
DEFINE_PRIM(_VOID,__bytes_output_set_big_endian,_ABSTRACT(realtime_bytes_output) _BOOL);
DEFINE_PRIM(_VOID,__bytes_output_write_byte,_ABSTRACT(realtime_bytes_output) _I32);
DEFINE_PRIM(_VOID,__bytes_output_write_i32,_ABSTRACT(realtime_bytes_output) _I32);
DEFINE_PRIM(_VOID,__bytes_output_write_f64,_ABSTRACT(realtime_bytes_output) _F64);
DEFINE_PRIM(_VOID,__bytes_output_write_string,_ABSTRACT(realtime_bytes_output) _BYTES);
DEFINE_PRIM(_VOID,__bytes_output_write,_ABSTRACT(realtime_bytes_output) _ABSTRACT(realtime_bytes));
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__bytes_output_get_bytes,_ABSTRACT(realtime_bytes_output));
DEFINE_PRIM(_VOID,__file_save_bytes,_BYTES _ABSTRACT(realtime_bytes));
DEFINE_PRIM(_ABSTRACT(realtime_date),__date_now,_NO_ARG);
DEFINE_PRIM(_F64,__date_get_time,_ABSTRACT(realtime_date));
DEFINE_PRIM(_BYTES,__array_join_bytes,_ARR _BYTES);
DEFINE_PRIM(_BYTES,__string_substring,_BYTES _I32 _I32);
DEFINE_PRIM(_BOOL,__exception_matches,_DYN _TYPE);
