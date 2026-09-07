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

#define DEFINE_ARRAY_REMOVE(SUFFIX, VALUE_TYPE, EQUALS) \
HL_PRIM bool HL_NAME(__array_remove_##SUFFIX)( varray *array, VALUE_TYPE value ) { \
	VALUE_TYPE *values = hl_aptr(array, VALUE_TYPE); \
	for (int index = 0; index < array->size; index++) { \
		if (!(EQUALS)) continue; \
		int stride = hl_type_size(array->at); \
		if (index + 1 < array->size) \
			memmove(hl_aptr(array, vbyte) + index * stride, hl_aptr(array, vbyte) + (index + 1) * stride, \
				(size_t)(array->size - index - 1) * stride); \
		array->size--; \
		memset(hl_aptr(array, vbyte) + array->size * stride, 0, (size_t)stride); \
		return true; \
	} \
	return false; \
}

DEFINE_ARRAY_REMOVE(i32, int, values[index] == value)
DEFINE_ARRAY_REMOVE(f64, double, values[index] == value)
DEFINE_ARRAY_REMOVE(bool, bool, values[index] == value)
DEFINE_ARRAY_REMOVE(bytes, vbyte *, realtime_bytes_equal(values[index], value))
DEFINE_ARRAY_REMOVE(ref, vdynamic *, values[index] == value)

#undef DEFINE_ARRAY_REMOVE

static void realtime_array_reverse(varray *array) {
	int stride = hl_type_size(array->at);
	vbyte *values = hl_aptr(array, vbyte);
	for (int left = 0, right = array->size - 1; left < right; left++, right--)
		for (int byte = 0; byte < stride; byte++) {
			vbyte value = values[left * stride + byte];
			values[left * stride + byte] = values[right * stride + byte];
			values[right * stride + byte] = value;
		}
}

#define DEFINE_ARRAY_REVERSE(SUFFIX) \
HL_PRIM void HL_NAME(__array_reverse_##SUFFIX)( varray *array ) { realtime_array_reverse(array); }

DEFINE_ARRAY_REVERSE(i32)
DEFINE_ARRAY_REVERSE(f64)
DEFINE_ARRAY_REVERSE(bytes)
DEFINE_ARRAY_REVERSE(bool)
DEFINE_ARRAY_REVERSE(ref)

#undef DEFINE_ARRAY_REVERSE

#define DEFINE_ARRAY_MUTATION(SUFFIX, VALUE_TYPE) \
HL_PRIM int HL_NAME(__array_push_##SUFFIX)( varray *array, VALUE_TYPE value ) { \
	if (array->size >= array->capacity) \
		hl_array_reserve(array, array->size + 1); \
	array->size++; \
	((VALUE_TYPE *)hl_aptr(array, vbyte))[array->size - 1] = value; \
	return array->size; \
} \
HL_PRIM int HL_NAME(__array_unshift_##SUFFIX)( varray *array, VALUE_TYPE value ) { \
	if (array->size >= array->capacity) \
		hl_array_reserve(array, array->size + 1); \
	int stride = hl_type_size(array->at); \
	memmove(hl_aptr(array, vbyte) + stride, hl_aptr(array, vbyte), (size_t)array->size * stride); \
	array->size++; \
	((VALUE_TYPE *)hl_aptr(array, vbyte))[0] = value; \
	return array->size; \
} \
HL_PRIM VALUE_TYPE HL_NAME(__array_pop_##SUFFIX)( varray *array ) { \
	if (array->size <= 0) \
		hl_error("Array.pop on an empty array"); \
	VALUE_TYPE value = ((VALUE_TYPE *)hl_aptr(array, vbyte))[array->size - 1]; \
	array->size--; \
	memset(hl_aptr(array, vbyte) + array->size * hl_type_size(array->at), 0, hl_type_size(array->at)); \
	return value; \
} \
HL_PRIM void HL_NAME(__array_resize_##SUFFIX)( varray *array, int length ) { \
	if (length < 0) \
		hl_error("Array.resize length must be non-negative"); \
	int old_length = array->size; \
	if (length > array->capacity) \
		hl_array_reserve(array, length); \
	int stride = hl_type_size(array->at); \
	if (length != old_length) \
		memset(hl_aptr(array, vbyte) + (length < old_length ? length : old_length) * stride, 0, \
			(size_t)(length > old_length ? length - old_length : old_length - length) * stride); \
	array->size = length; \
}

DEFINE_ARRAY_MUTATION(i32, int)
DEFINE_ARRAY_MUTATION(f64, double)
DEFINE_ARRAY_MUTATION(bytes, vbyte *)
DEFINE_ARRAY_MUTATION(bool, bool)
DEFINE_ARRAY_MUTATION(ref, vdynamic *)

#undef DEFINE_ARRAY_MUTATION

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
