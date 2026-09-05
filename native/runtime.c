#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>
#include <string.h>

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
	if( status == HL_RUNTIME_EXCEPTION ) hl_throw(exception);
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime function call");
	return result;
}

HL_PRIM void HL_NAME(call_void)( hl_runtime_module *runtime, int stable_id ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_void(runtime,stable_id,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) hl_throw(exception);
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime void function call (status %d)",status);
}

HL_PRIM vbyte *HL_NAME(call_bytes)( hl_runtime_module *runtime, int stable_id ) {
	vbyte *result = NULL;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes(runtime,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) hl_throw(exception);
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime string function call (status %d)",status);
	return result;
}

HL_PRIM void HL_NAME(call_bytes1)( hl_runtime_module *runtime, int stable_id, vbyte *argument ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes1(runtime,stable_id,argument,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) hl_throw(exception);
	if( status != HL_RUNTIME_OK ) hl_error("Invalid runtime string argument function call (status %d)",status);
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
DEFINE_PRIM(_I32,patch,_ABSTRACT(realtime_module) _BYTES _I32);
DEFINE_PRIM(_I32,allocation_count,_ABSTRACT(realtime_module));
DEFINE_PRIM(_I32,patch_jit_count,_ABSTRACT(realtime_module));
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
DEFINE_PRIM(_BYTES,__string_substring,_BYTES _I32 _I32);
DEFINE_PRIM(_BOOL,__exception_matches,_DYN _TYPE);
