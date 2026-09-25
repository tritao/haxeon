HL_PRIM bool HL_NAME(__exception_matches)( vdynamic *value, hl_type *type ) {
	return value != NULL && type != NULL && hl_safe_cast(value->t,type);
}

HL_PRIM bool HL_NAME(__std_is_of_type)(vdynamic *value, hl_type *type) {
	return value != NULL && type != NULL && hl_safe_cast(value->t, type);
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

HL_PRIM varray *HL_NAME(__array_alloc_i64)( int length ) {
	return hl_alloc_array(&hlt_i64, length);
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

HL_PRIM varray *HL_NAME(__array_alloc_typed_ref)( int length, hl_type *elementType ) {
	if (elementType == NULL || !hl_is_ptr(elementType))
		hl_error("Invalid reference array element type");
	return hl_alloc_array(elementType, length);
}

/* Haxe spelling for array diagnostics; composite types keep HashLink's description. */
static const uchar *realtime_array_type_name(hl_type *type) {
	switch (type->kind) {
	case HI32: return USTR("Int");
	case HI64: return USTR("Int64");
	case HF64: return USTR("Float");
	case HF32: return USTR("Single");
	case HBOOL: return USTR("Bool");
	case HBYTES: return USTR("String");
	case HDYN: return USTR("Dynamic");
	default: return hl_type_str(type);
	}
}

static void realtime_array_retype_mismatch(varray *array, hl_type *elementType, int index, vdynamic *value) {
	hl_error("Array element type mismatch: %s -> %s (element %d is %s)", realtime_array_type_name(array->at),
		realtime_array_type_name(elementType), index, value == NULL ? USTR("null") : realtime_array_type_name(value->t));
}

/* True when a dynamic value converts to the element type without changing its meaning. */
static bool realtime_array_accepts(hl_type *elementType, vdynamic *value) {
	switch (elementType->kind) {
	case HUI8: case HUI16: case HI32: case HI64: case HF32: case HF64: case HBOOL:
		if (value == NULL) return false;
		switch (value->t->kind) {
		case HUI8: case HUI16: case HI32: case HI64:
			return elementType->kind != HBOOL;
		case HF32: case HF64:
			/* Int storage never truncates a Float. */
			return elementType->kind == HF32 || elementType->kind == HF64;
		case HBOOL:
			return elementType->kind == HBOOL;
		default:
			return false;
		}
	case HBYTES:
		return value == NULL || value->t->kind == HBYTES;
	case HOBJ: case HENUM: case HARRAY: case HFUN:
		return value == NULL || hl_safe_cast(value->t, elementType);
	default:
		/* Virtuals and nullable boxes convert through HashLink's own cast. */
		return true;
	}
}

/* Arrays created for dynamic values (Array<Dynamic>, erased generic code, JSON) take their
   element type when first viewed through a concrete Array<T>, as HashLink's ArrayDyn does.
   Aliases stay valid: until then only Array<Dynamic> views exist, and those read through the
   current element type. Every element is converted into new storage before the array changes,
   so a rejected element leaves the array untouched. */
static void realtime_array_retype(varray *array, hl_type *elementType) {
	vdynamic **values = hl_aptr(array, vdynamic *);
	for (int i = 0; i < array->size; i++)
		if (!realtime_array_accepts(elementType, values[i]))
			realtime_array_retype_mismatch(array, elementType, i, values[i]);
	varray *storage = hl_alloc_array(elementType, array->capacity > 0 ? array->capacity : 1);
	int stride = hl_type_size(elementType);
	for (int i = 0; i < array->size; i++) {
		vdynamic *value = values[i];
		void *slot = hl_aptr(storage, vbyte) + (size_t)i * stride;
		if (hl_is_ptr(elementType) && !hl_is_dynamic(elementType))
			*(void **)slot = value == NULL ? NULL : hl_dyn_castp(&value, &hlt_dyn, elementType);
		else
			hl_write_dyn(slot, elementType, value, false);
	}
	array->data = storage->data;
	array->capacity = storage->capacity;
	array->at = elementType;
}

/* Concrete array views require exact storage; dynamic storage is retyped on the first view. */
HL_PRIM varray *HL_NAME(__array_check_cast)( varray *array, hl_type *elementType ) {
	if (elementType == NULL)
		hl_error("Invalid array element type");
	if (array == NULL || hl_same_type(array->at, elementType) || elementType->kind == HDYN)
		return array;
	if (array->at->kind == HDYN) {
		realtime_array_retype(array, elementType);
		return array;
	}
	hl_error("Array element type mismatch: %s -> %s", realtime_array_type_name(array->at), realtime_array_type_name(elementType));
	return array;
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

static varray *realtime_array_splice(varray *array, int position, int length) {
	if (length < 0 || position > array->size)
		return hl_alloc_array(array->at, 0);
	if (position < 0) {
		position += array->size;
		if (position < 0) position = 0;
	}
	if (length > array->size - position)
		length = array->size - position;
	if (length < 0) length = 0;
	varray *removed = hl_alloc_array(array->at, length);
	int stride = hl_type_size(array->at);
	vbyte *values = hl_aptr(array, vbyte);
	if (length > 0) {
		memcpy(hl_aptr(removed, vbyte), values + position * stride, (size_t)length * stride);
		memmove(values + position * stride, values + (position + length) * stride,
			(size_t)(array->size - position - length) * stride);
		array->size -= length;
		memset(values + array->size * stride, 0, (size_t)length * stride);
	}
	return removed;
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
	for (int i = 0; i < dynamicValues->size; i++) {
		void *slot = hl_aptr(result, vbyte) + i * stride;
		/* Map strings are boxed as vdynamic; an HBYTES array stores the inner byte pointer. */
		if (valueType->kind == HBYTES)
			*(void **)slot = source[i] == NULL ? NULL : source[i]->v.bytes;
		else
			hl_write_dyn(slot, valueType, source[i], false);
	}
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
HL_PRIM varray *HL_NAME(__array_slice_##SUFFIX)( varray *array, int start, int end ) { return realtime_array_slice(array, start, end); } \
HL_PRIM varray *HL_NAME(__array_splice_##SUFFIX)( varray *array, int position, int length ) { return realtime_array_splice(array, position, length); }

DEFINE_ARRAY_COPY(i32)
DEFINE_ARRAY_COPY(i64)
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
DEFINE_ARRAY_INDEX_OF(i64, int64_t, values[i] == value)
DEFINE_ARRAY_INDEX_OF(f64, double, values[i] == value)
DEFINE_ARRAY_INDEX_OF(bool, bool, values[i] == value)
DEFINE_ARRAY_INDEX_OF(bytes, vbyte *, realtime_bytes_equal(values[i], value))
DEFINE_ARRAY_INDEX_OF(ref, void *, values[i] == value)

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
DEFINE_ARRAY_REMOVE(i64, int64_t, values[index] == value)
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
DEFINE_ARRAY_REVERSE(i64)
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
HL_PRIM void HL_NAME(__array_insert_##SUFFIX)( varray *array, int position, VALUE_TYPE value ) { \
	if (position < 0) position += array->size; \
	if (position < 0) position = 0; \
	if (position > array->size) position = array->size; \
	if (array->size >= array->capacity) \
		hl_array_reserve(array, array->size + 1); \
	int stride = hl_type_size(array->at); \
	vbyte *values = hl_aptr(array, vbyte); \
	memmove(values + (position + 1) * stride, values + position * stride, (size_t)(array->size - position) * stride); \
	array->size++; \
	((VALUE_TYPE *)values)[position] = value; \
} \
HL_PRIM VALUE_TYPE HL_NAME(__array_pop_##SUFFIX)( varray *array ) { \
	if (array->size <= 0) \
		hl_error("Array.pop on an empty array"); \
	VALUE_TYPE value = ((VALUE_TYPE *)hl_aptr(array, vbyte))[array->size - 1]; \
	array->size--; \
	memset(hl_aptr(array, vbyte) + array->size * hl_type_size(array->at), 0, hl_type_size(array->at)); \
	return value; \
} \
HL_PRIM VALUE_TYPE HL_NAME(__array_shift_##SUFFIX)( varray *array ) { \
	if (array->size <= 0) \
		hl_error("Array.shift on an empty array"); \
	VALUE_TYPE value = ((VALUE_TYPE *)hl_aptr(array, vbyte))[0]; \
	int stride = hl_type_size(array->at); \
	array->size--; \
	memmove(hl_aptr(array, vbyte), hl_aptr(array, vbyte) + stride, (size_t)array->size * stride); \
	memset(hl_aptr(array, vbyte) + array->size * stride, 0, stride); \
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
DEFINE_ARRAY_MUTATION(i64, int64_t)
DEFINE_ARRAY_MUTATION(f64, double)
DEFINE_ARRAY_MUTATION(bytes, vbyte *)
DEFINE_ARRAY_MUTATION(bool, bool)
DEFINE_ARRAY_MUTATION(ref, vdynamic *)

#undef DEFINE_ARRAY_MUTATION

/* Array<Dynamic>, including arrays seen through an erased type parameter, may alias storage
   of any element type. These operations read and write through the array's own element type:
   values are boxed on read and checked or unboxed on write. */
HL_PRIM bool HL_NAME(__dynamic_equal)(vdynamic *left, vdynamic *right);
HL_PRIM void HL_NAME(__array_insert_any)( varray *array, int position, vdynamic *value );

static void *realtime_any_slot(varray *array, int index) {
	return hl_aptr(array, vbyte) + (size_t)index * (size_t)hl_type_size(array->at);
}

static vdynamic *realtime_any_read(varray *array, int index) {
	return hl_make_dyn(realtime_any_slot(array, index), array->at);
}

/* Dynamic equality: identity first, then value equality for boxed numbers and strings. */
static bool realtime_any_equal(varray *array, int index, vdynamic *value) {
	vdynamic *element = realtime_any_read(array, index);
	return element == value || HL_NAME(__dynamic_equal)(element, value);
}

/* Converts a value to the array's element representation before any structural change,
   so a rejected value leaves the array untouched. */
typedef union { int64 bits; double number; void *pointer; } realtime_any_element;

static realtime_any_element realtime_any_encode(varray *array, vdynamic *value) {
	realtime_any_element element;
	element.bits = 0;
	hl_type *type = array->at;
	if (type->kind == HDYN)
		element.pointer = value;
	else if (hl_is_ptr(type) && !hl_is_dynamic(type))
		/* Strings and other headerless pointers are boxed as vdynamic; store the unboxed pointer. */
		element.pointer = hl_dyn_castp(&value, &hlt_dyn, type);
	else
		hl_write_dyn(&element, type, value, false);
	return element;
}

static void realtime_any_store(varray *array, int index, realtime_any_element element) {
	memcpy(realtime_any_slot(array, index), &element, hl_type_size(array->at));
}

static void realtime_any_reserve(varray *array, int size) {
	if (size > array->capacity)
		hl_array_reserve(array, size);
}

HL_PRIM vdynamic *HL_NAME(__array_get_any)( varray *array, int index ) {
	hl_array_check(array, index);
	return realtime_any_read(array, index);
}

HL_PRIM void HL_NAME(__array_set_any)( varray *array, int index, vdynamic *value ) {
	realtime_any_element element = realtime_any_encode(array, value);
	int size = array->size;
	hl_array_ensure(array, index);
	if (array->size > size) {
		int stride = hl_type_size(array->at);
		memset(hl_aptr(array, vbyte) + (size_t)size * stride, 0, (size_t)(array->size - size) * stride);
	}
	realtime_any_store(array, index, element);
}

HL_PRIM int HL_NAME(__array_push_any)( varray *array, vdynamic *value ) {
	realtime_any_element element = realtime_any_encode(array, value);
	realtime_any_reserve(array, array->size + 1);
	array->size++;
	realtime_any_store(array, array->size - 1, element);
	return array->size;
}

HL_PRIM int HL_NAME(__array_unshift_any)( varray *array, vdynamic *value ) {
	HL_NAME(__array_insert_any)(array, 0, value);
	return array->size;
}

HL_PRIM void HL_NAME(__array_insert_any)( varray *array, int position, vdynamic *value ) {
	realtime_any_element element = realtime_any_encode(array, value);
	if (position < 0) position += array->size;
	if (position < 0) position = 0;
	if (position > array->size) position = array->size;
	realtime_any_reserve(array, array->size + 1);
	int stride = hl_type_size(array->at);
	vbyte *values = hl_aptr(array, vbyte);
	memmove(values + (position + 1) * stride, values + position * stride, (size_t)(array->size - position) * stride);
	array->size++;
	realtime_any_store(array, position, element);
}

HL_PRIM vdynamic *HL_NAME(__array_pop_any)( varray *array ) {
	if (array->size <= 0)
		hl_error("Array.pop on an empty array");
	vdynamic *value = realtime_any_read(array, array->size - 1);
	array->size--;
	memset(realtime_any_slot(array, array->size), 0, hl_type_size(array->at));
	return value;
}

HL_PRIM vdynamic *HL_NAME(__array_shift_any)( varray *array ) {
	if (array->size <= 0)
		hl_error("Array.shift on an empty array");
	vdynamic *value = realtime_any_read(array, 0);
	int stride = hl_type_size(array->at);
	array->size--;
	memmove(hl_aptr(array, vbyte), hl_aptr(array, vbyte) + stride, (size_t)array->size * stride);
	memset(hl_aptr(array, vbyte) + array->size * stride, 0, stride);
	return value;
}

HL_PRIM int HL_NAME(__array_index_of_any)( varray *array, vdynamic *value ) {
	for (int i = 0; i < array->size; i++)
		if (realtime_any_equal(array, i, value)) return i;
	return -1;
}

HL_PRIM bool HL_NAME(__array_remove_any)( varray *array, vdynamic *value ) {
	int index = HL_NAME(__array_index_of_any)(array, value);
	if (index < 0) return false;
	int stride = hl_type_size(array->at);
	vbyte *values = hl_aptr(array, vbyte);
	memmove(values + index * stride, values + (index + 1) * stride, (size_t)(array->size - index - 1) * stride);
	array->size--;
	memset(values + array->size * stride, 0, stride);
	return true;
}

/* Mixed storage concatenates into dynamic storage; equal storage keeps its element type. */
HL_PRIM varray *HL_NAME(__array_concat_any)( varray *left, varray *right ) {
	if (left->at == right->at)
		return realtime_array_concat(left, right);
	varray *result = hl_alloc_array(&hlt_dyn, left->size + right->size);
	vdynamic **values = hl_aptr(result, vdynamic *);
	for (int i = 0; i < left->size; i++) values[i] = realtime_any_read(left, i);
	for (int i = 0; i < right->size; i++) values[left->size + i] = realtime_any_read(right, i);
	return result;
}

HL_PRIM varray *HL_NAME(__array_copy_any)( varray *array ) { return realtime_array_copy(array); }
HL_PRIM varray *HL_NAME(__array_slice_any)( varray *array, int start, int end ) { return realtime_array_slice(array, start, end); }
HL_PRIM varray *HL_NAME(__array_splice_any)( varray *array, int position, int length ) { return realtime_array_splice(array, position, length); }
HL_PRIM void HL_NAME(__array_reverse_any)( varray *array ) { realtime_array_reverse(array); }

HL_PRIM void HL_NAME(__array_resize_any)( varray *array, int length ) {
	if (length < 0)
		hl_error("Array.resize length must be non-negative");
	int old_length = array->size;
	realtime_any_reserve(array, length);
	int stride = hl_type_size(array->at);
	if (length != old_length)
		memset(hl_aptr(array, vbyte) + (length < old_length ? length : old_length) * stride, 0,
			(size_t)(length > old_length ? length - old_length : old_length - length) * stride);
	array->size = length;
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
