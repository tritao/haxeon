/* Inline struct arrays keep a scalar lane separate from the references traced by the collector. */
#include <limits.h>

/* HARRAY has the same runtime type identity as an ordinary HashLink array, but this distinct type word lets dynamic
 * array operations recognize the extended header without reading past an ordinary varray. */
static vdynamic *realtime_value_array_access(varray *array, int index);
static hl_array_access realtime_value_array_accessors = { realtime_value_array_access };
static hl_type realtime_value_array_type = { .kind = HARRAY, .array_access = &realtime_value_array_accessors };
/* A pre-existing Array<Dynamic> header cannot grow; its data field roots this same lane descriptor instead. */
static hl_type realtime_value_array_forward_type = { .kind = HARRAY, .array_access = &realtime_value_array_accessors };

typedef struct {
	varray array;
	vbyte *references;     /* Exact GC allocation base, or null when there are no reference fields. */
	vbyte *pending_scalar; /* Keep new lanes rooted until a growth operation commits. */
	vbyte *pending_references;
	/* Shared, type-specific accessors are used only when an element escapes through Dynamic. */
	vclosure *dynamic_read;
	vclosure *dynamic_write;
	vclosure *dynamic_accepts;
	varray *forward_header;
	int scalar_stride_bits;
	int reference_stride;
	int word_bits;
	bool has_validity;
} realtime_value_array;

static realtime_value_array *realtime_value_array_require(varray *array) {
	if( array != NULL && array->t == &realtime_value_array_forward_type )
		return (realtime_value_array*)array->data;
	if( array == NULL || array->t != &realtime_value_array_type )
		hl_error("Expected an inline value array");
	return (realtime_value_array*)array;
}

static void realtime_value_array_sync(realtime_value_array *array) {
	if( array->forward_header != NULL ) {
		array->forward_header->size = array->array.size;
		array->forward_header->capacity = array->array.capacity;
	}
}

static uint64_t realtime_value_array_payload_words(realtime_value_array *array, int capacity) {
	uint64_t bits = (uint64_t)(unsigned int)capacity * (unsigned int)array->scalar_stride_bits;
	return (bits + (unsigned int)array->word_bits - 1) / (unsigned int)array->word_bits;
}

static int realtime_value_array_scalar_bytes(realtime_value_array *array, int capacity) {
	uint64_t words = realtime_value_array_payload_words(array, capacity);
	if( array->has_validity )
		words += ((uint64_t)(unsigned int)capacity + (unsigned int)array->word_bits - 1) / (unsigned int)array->word_bits;
	uint64_t bytes = words * ((unsigned int)array->word_bits / 8);
	if( bytes > INT_MAX - HL_WSIZE ) hl_error("Value array scalar lane is too large");
	return (int)bytes;
}

static int realtime_value_array_reference_bytes(realtime_value_array *array, int capacity) {
	uint64_t slots = (uint64_t)(unsigned int)capacity * (unsigned int)array->reference_stride;
	if( slots > (INT_MAX - HL_WSIZE) / sizeof(void*) ) hl_error("Value array reference lane is too large");
	return (int)(slots * sizeof(void*));
}

static vbyte *realtime_value_array_alloc_lane(realtime_value_array *array, int bytes, bool references) {
	vbyte *lane = (vbyte*)hl_gc_alloc_gen_owner(&hlt_array, HL_WSIZE + bytes,
		(references ? MEM_KIND_DYNAMIC : MEM_KIND_NOPTR) | MEM_ZERO, array->array.at->gc_owner);
	*(hl_type**)lane = &hlt_array;
	return lane;
}

static vbyte *realtime_value_array_validity(realtime_value_array *array, vbyte *scalar, int capacity) {
	return scalar + HL_WSIZE + (size_t)realtime_value_array_payload_words(array, capacity) * (array->word_bits / 8);
}

static bool realtime_value_array_valid_at(realtime_value_array *array, int index) {
	if( !array->has_validity ) return true;
	vbyte *bits = realtime_value_array_validity(array, array->array.data, array->array.capacity);
	return (bits[index >> 3] & (1u << (index & 7))) != 0;
}

static void realtime_value_array_set_valid(realtime_value_array *array, int index, bool value) {
	if( !array->has_validity ) return;
	vbyte *bits = realtime_value_array_validity(array, array->array.data, array->array.capacity);
	unsigned int mask = 1u << (index & 7);
	if( value ) bits[index >> 3] |= mask; else bits[index >> 3] &= ~mask;
}

static void realtime_value_array_check_index(realtime_value_array *array, int index) {
	if( index < 0 || index >= array->array.size ) hl_error("Array index out of bounds");
}

static void realtime_value_array_check_read(realtime_value_array *array, int index) {
	realtime_value_array_check_index(array, index);
	if( !realtime_value_array_valid_at(array, index) ) hl_error("Null access");
}

/* A growth allocates both lanes before changing the live header. Pending slots root the new blocks, and the trap
 * clears them if an allocation throws, so the old array and its aliases retain their prior contents. */
static void realtime_value_array_reserve(realtime_value_array *array, int capacity) {
	if( capacity <= array->array.capacity ) return;
	int next = array->array.capacity < 4 ? 4 : array->array.capacity;
	while( next < capacity ) {
		int64_t grown = (int64_t)next + next / 2;
		if( grown > INT_MAX || grown <= next ) { next = capacity; break; }
		next = (int)grown;
	}
	int scalar_bytes = realtime_value_array_scalar_bytes(array, next);
	int reference_bytes = realtime_value_array_reference_bytes(array, next);
	int old_capacity = array->array.capacity, size = array->array.size;
	vbyte *old_scalar = array->array.data, *old_references = array->references;
	hl_trap_ctx trap;
	vdynamic *error = NULL;
	hl_trap(trap, error, failed);
	vbyte *scalar = realtime_value_array_alloc_lane(array, scalar_bytes, false);
	hl_gc_store_ref(&array->pending_scalar, scalar, &hlt_bytes);
	vbyte *references = NULL;
	if( reference_bytes != 0 ) {
		references = realtime_value_array_alloc_lane(array, reference_bytes, true);
		hl_gc_store_ref(&array->pending_references, references, &hlt_bytes);
	}
	if( size != 0 ) {
		size_t payload = (size_t)size * (array->scalar_stride_bits / 8);
		if( payload != 0 ) memcpy(scalar + HL_WSIZE, old_scalar + HL_WSIZE, payload);
		if( array->has_validity ) {
			vbyte *source = realtime_value_array_validity(array, old_scalar, old_capacity);
			vbyte *target = realtime_value_array_validity(array, scalar, next);
			memcpy(target, source, ((size_t)size + 7) / 8);
		}
		if( array->reference_stride != 0 )
			hl_gc_copy_values(references + HL_WSIZE, old_references + HL_WSIZE,
				(size_t)size * array->reference_stride * sizeof(void*), &hlt_dyn);
	}
	hl_gc_store_ref(&array->array.data, scalar, &hlt_bytes);
	hl_gc_store_ref(&array->references, references, &hlt_bytes);
	array->array.capacity = next;
	realtime_value_array_sync(array);
	hl_gc_store_ref(&array->pending_scalar, NULL, &hlt_bytes);
	hl_gc_store_ref(&array->pending_references, NULL, &hlt_bytes);
	hl_endtrap(trap);
	return;
failed:
	hl_endtrap(trap);
	hl_gc_store_ref(&array->pending_scalar, NULL, &hlt_bytes);
	hl_gc_store_ref(&array->pending_references, NULL, &hlt_bytes);
	hl_rethrow(error);
}

HL_PRIM varray *HL_NAME(__value_array_alloc)(int length, hl_type *element, int scalar_stride_bits, int reference_stride,
	int word_bits, bool has_validity) {
	if( length < 0 || element == NULL || element->kind != HSTRUCT || scalar_stride_bits < 0 || (scalar_stride_bits & 7)
		|| reference_stride < 0 || (word_bits != 32 && word_bits != 64) )
		hl_error("Invalid inline value array layout");
	realtime_value_array *array = (realtime_value_array*)hl_gc_alloc_gen_owner(&realtime_value_array_type,
		sizeof(realtime_value_array), MEM_KIND_DYNAMIC | MEM_ZERO, element->gc_owner);
	array->array.t = &realtime_value_array_type;
	array->array.at = element;
	array->scalar_stride_bits = scalar_stride_bits;
	array->reference_stride = reference_stride;
	array->word_bits = word_bits;
	array->has_validity = has_validity;
	/* Empty arrays keep no backing lanes until their first write. Non-empty allocations
	 * reserve with size zero so new slots and the validity bitmap start clear. */
	realtime_value_array_reserve(array, length);
	array->array.size = length;
	return &array->array;
}

HL_PRIM bool HL_NAME(__value_array_is)(varray *array) {
	return array != NULL && (array->t == &realtime_value_array_type || array->t == &realtime_value_array_forward_type);
}

HL_PRIM bool HL_NAME(__value_array_compatible)(varray *left, varray *right) {
	if( !HL_NAME(__value_array_is)(left) || !HL_NAME(__value_array_is)(right) ) return false;
	realtime_value_array *a = realtime_value_array_require(left), *b = realtime_value_array_require(right);
	return hl_same_type(a->array.at, b->array.at) && a->scalar_stride_bits == b->scalar_stride_bits
		&& a->reference_stride == b->reference_stride && a->word_bits == b->word_bits && a->has_validity == b->has_validity;
}

HL_PRIM void HL_NAME(__value_array_set_bridge)(varray *value, vclosure *read, vclosure *write, vclosure *accepts) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( read == NULL || write == NULL || accepts == NULL ) hl_error("Invalid inline value array bridge");
	hl_gc_store_ref(&array->dynamic_read, read, &hlt_dyn);
	hl_gc_store_ref(&array->dynamic_write, write, &hlt_dyn);
	hl_gc_store_ref(&array->dynamic_accepts, accepts, &hlt_dyn);
}

static vdynamic *realtime_value_array_access(varray *array, int index) {
	return HL_NAME(__value_array_dynamic_read)(array, index);
}

HL_PRIM vdynamic *HL_NAME(__value_array_dynamic_read)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	if( !realtime_value_array_valid_at(array, index) ) return NULL;
	if( array->dynamic_read == NULL ) hl_error("Missing inline value array read bridge");
	return hl_call2(vdynamic*, array->dynamic_read, varray*, value, int, index);
}

HL_PRIM bool HL_NAME(__value_array_dynamic_accepts)(varray *value, vdynamic *input) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( array->dynamic_accepts == NULL ) hl_error("Missing inline value array type bridge");
	return hl_call1(bool, array->dynamic_accepts, vdynamic*, input);
}

HL_PRIM void HL_NAME(__value_array_dynamic_write)(varray *value, int index, vdynamic *input) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( array->dynamic_write == NULL ) hl_error("Missing inline value array write bridge");
	hl_call3(void, array->dynamic_write, varray*, value, int, index, vdynamic*, input);
}

static vdynamic *realtime_value_array_escape_element(varray *source, vdynamic **values, int index, hl_type *element) {
	if( source->at->kind == HDYN || values[index] == NULL ) return values[index];
	/* A native Array<S> contains raw HSTRUCT pointers, which have no Dynamic header of their own. */
	vdynamic *boxed = hl_alloc_dynamic(element);
	hl_gc_store_ref(&boxed->v.ptr, values[index], element);
	return boxed;
}

/* Retype an escaped dynamic array without changing its identity or any aliases. Build and populate the new lanes
 * first, so a rejected value or an exception leaves the original header and backing values untouched. */
HL_PRIM varray *HL_NAME(__value_array_retype)(varray *value, hl_type *element, int scalar_stride_bits, int reference_stride,
	int word_bits, bool has_validity, vclosure *read, vclosure *write, vclosure *accepts) {
	if( value == NULL ) return NULL;
	if( HL_NAME(__value_array_is)(value) ) {
		realtime_value_array *existing = realtime_value_array_require(value);
		if( !hl_same_type(existing->array.at, element) || existing->scalar_stride_bits != scalar_stride_bits
			|| existing->reference_stride != reference_stride || existing->word_bits != word_bits
			|| existing->has_validity != has_validity ) hl_error("Array element type mismatch");
		return value;
	}
	if( element == NULL || read == NULL || write == NULL || accepts == NULL
		|| (value->at->kind != HDYN && !hl_same_type(value->at, element)) )
		hl_error("Array element type mismatch");
	int length = value->size;
	vdynamic **values = hl_aptr(value, vdynamic*);
	for( int i = 0; i < length; i++ ) {
		vdynamic *item = realtime_value_array_escape_element(value, values, i, element);
		if( !(has_validity && item == NULL) && !hl_call1(bool, accepts, vdynamic*, item) )
			hl_error("Array element type mismatch");
	}
	varray *candidate = HL_NAME(__value_array_alloc)(length, element, scalar_stride_bits, reference_stride, word_bits, has_validity);
	HL_NAME(__value_array_set_bridge)(candidate, read, write, accepts);
	for( int i = 0; i < length; i++ ) {
		vdynamic *item = realtime_value_array_escape_element(value, values, i, element);
		if( !(has_validity && item == NULL) )
			HL_NAME(__value_array_dynamic_write)(candidate, i, item);
	}
	realtime_value_array *array = realtime_value_array_require(candidate);
	hl_gc_store_ref(&array->forward_header, value, &hlt_dyn);
	hl_gc_store_ref(&value->data, candidate, &hlt_bytes);
	value->at = element;
	value->capacity = candidate->capacity;
	value->t = &realtime_value_array_forward_type;
	return value;
}

HL_PRIM void HL_NAME(__value_array_ensure)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( index < 0 || index == INT_MAX ) hl_error("Array index out of bounds");
	if( index >= array->array.size ) {
		realtime_value_array_reserve(array, index + 1);
		array->array.size = index + 1;
		realtime_value_array_sync(array);
	}
}

HL_PRIM void HL_NAME(__value_array_validate)(varray *value, int index) {
	realtime_value_array_check_read(realtime_value_array_require(value), index);
}

HL_PRIM bool HL_NAME(__value_array_is_initialized)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	return realtime_value_array_valid_at(array, index);
}

HL_PRIM void HL_NAME(__value_array_mark)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	realtime_value_array_set_valid(array, index, true);
}

/* Clearing a nullable element must release its references as well as its presence and payload bits. */
HL_PRIM void HL_NAME(__value_array_clear)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	size_t scalar_stride = array->scalar_stride_bits / 8;
	if( scalar_stride != 0 )
		memset(array->array.data + HL_WSIZE + (size_t)index * scalar_stride, 0, scalar_stride);
	if( array->reference_stride != 0 )
		hl_gc_clear_values(array->references + HL_WSIZE + (size_t)index * array->reference_stride * sizeof(void*),
			(size_t)array->reference_stride * sizeof(void*), &hlt_dyn);
	realtime_value_array_set_valid(array, index, false);
}

static vbyte *realtime_value_array_scalar_slot(realtime_value_array *array, int index, int offset, int width, bool reading) {
	if( reading ) realtime_value_array_check_read(array, index); else realtime_value_array_check_index(array, index);
	if( offset < 0 || (offset & 7) || (width != 8 && width != 16 && width != 32 && width != 64)
		|| offset > array->scalar_stride_bits || width > array->scalar_stride_bits - offset )
		hl_error("Invalid inline value scalar slot");
	return array->array.data + HL_WSIZE + (size_t)index * (array->scalar_stride_bits / 8) + offset / 8;
}

HL_PRIM void HL_NAME(__value_array_clear_scalar)(varray *value, int index, int offset, int width) {
	memset(realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, width, false), 0, width / 8);
}

HL_PRIM int HL_NAME(__value_array_read_i32)(varray *value, int index, int offset, int width, bool sign) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( width > 32 ) hl_error("Invalid inline value Int slot");
	vbyte *slot = realtime_value_array_scalar_slot(array, index, offset, width, true);
	uint32_t bits = 0;
	memcpy(&bits, slot, width / 8);
	if( sign && width < 32 && (bits & ((uint32_t)1 << (width - 1))) ) bits |= UINT32_MAX << width;
	int result;
	memcpy(&result, &bits, sizeof(result));
	return result;
}

HL_PRIM int64_t HL_NAME(__value_array_read_i64)(varray *value, int index, int offset, int width, bool sign) {
	realtime_value_array *array = realtime_value_array_require(value);
	vbyte *slot = realtime_value_array_scalar_slot(array, index, offset, width, true);
	uint64_t bits = 0;
	memcpy(&bits, slot, width / 8);
	if( sign && width < 64 && (bits & ((uint64_t)1 << (width - 1))) ) bits |= UINT64_MAX << width;
	int64_t result;
	memcpy(&result, &bits, sizeof(result));
	return result;
}

HL_PRIM void HL_NAME(__value_array_write_i32)(varray *value, int index, int offset, int width, int input) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( width > 32 ) hl_error("Invalid inline value Int slot");
	vbyte *slot = realtime_value_array_scalar_slot(array, index, offset, width, false);
	memcpy(slot, &input, width / 8);
}

HL_PRIM void HL_NAME(__value_array_write_i64)(varray *value, int index, int offset, int width, int64_t input) {
	realtime_value_array *array = realtime_value_array_require(value);
	vbyte *slot = realtime_value_array_scalar_slot(array, index, offset, width, false);
	memcpy(slot, &input, width / 8);
}

HL_PRIM bool HL_NAME(__value_array_read_bool)(varray *value, int index, int offset) {
	return *realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 8, true) != 0;
}

HL_PRIM void HL_NAME(__value_array_write_bool)(varray *value, int index, int offset, bool input) {
	*realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 8, false) = input ? 1 : 0;
}

HL_PRIM vbyte *HL_NAME(__value_array_read_ptr)(varray *value, int index, int offset, int width) {
	if( width != 32 && width != 64 ) hl_error("Invalid inline value pointer slot");
	if( width > (int)(sizeof(uintptr_t) * 8) ) hl_error("Inline value pointer exceeds host width");
	uintptr_t bits = 0;
	memcpy(&bits, realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, width, true), width / 8);
	return (vbyte*)bits;
}

HL_PRIM void HL_NAME(__value_array_write_ptr)(varray *value, int index, int offset, int width, vbyte *input) {
	if( width != 32 && width != 64 ) hl_error("Invalid inline value pointer slot");
	if( width > (int)(sizeof(uintptr_t) * 8) ) hl_error("Inline value pointer exceeds host width");
	uintptr_t bits = (uintptr_t)input;
	if( width == 32 && (uint64_t)bits > UINT32_MAX ) hl_error("Inline value pointer does not fit the target width");
	memcpy(realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, width, false), &bits, width / 8);
}

HL_PRIM hl_type *HL_NAME(__value_array_read_type)(varray *value, int index, int offset, int width) {
	return (hl_type*)HL_NAME(__value_array_read_ptr)(value, index, offset, width);
}

HL_PRIM void HL_NAME(__value_array_write_type)(varray *value, int index, int offset, int width, hl_type *input) {
	HL_NAME(__value_array_write_ptr)(value, index, offset, width, (vbyte*)input);
}

HL_PRIM float HL_NAME(__value_array_read_f32)(varray *value, int index, int offset) {
	float result;
	memcpy(&result, realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 32, true), sizeof(result));
	return result;
}

HL_PRIM double HL_NAME(__value_array_read_f64)(varray *value, int index, int offset) {
	double result;
	memcpy(&result, realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 64, true), sizeof(result));
	return result;
}

HL_PRIM void HL_NAME(__value_array_write_f32)(varray *value, int index, int offset, float input) {
	memcpy(realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 32, false), &input, sizeof(input));
}

HL_PRIM void HL_NAME(__value_array_write_f64)(varray *value, int index, int offset, double input) {
	memcpy(realtime_value_array_scalar_slot(realtime_value_array_require(value), index, offset, 64, false), &input, sizeof(input));
}

HL_PRIM vdynamic *HL_NAME(__value_array_read_ref)(varray *value, int index, int field) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_read(array, index);
	if( field < 0 || field >= array->reference_stride ) hl_error("Invalid inline value reference slot");
	return ((vdynamic**)(array->references + HL_WSIZE))[(size_t)index * array->reference_stride + field];
}

HL_PRIM void HL_NAME(__value_array_write_ref)(varray *value, int index, int field, vdynamic *input) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	if( field < 0 || field >= array->reference_stride ) hl_error("Invalid inline value reference slot");
	vdynamic **slot = ((vdynamic**)(array->references + HL_WSIZE)) + (size_t)index * array->reference_stride + field;
	hl_gc_store_ref(slot, input, &hlt_dyn);
}

HL_PRIM void HL_NAME(__value_array_clear_ref)(varray *value, int index, int field) {
	HL_NAME(__value_array_write_ref)(value, index, field, NULL);
}

HL_PRIM void HL_NAME(__value_array_resize)(varray *value, int length) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( length < 0 ) hl_error("Array.resize length must be non-negative");
	int old_length = array->array.size;
	if( length > old_length ) realtime_value_array_reserve(array, length);
	if( length < old_length ) {
		int removed = old_length - length;
		size_t stride = array->scalar_stride_bits / 8;
		if( stride != 0 ) memset(array->array.data + HL_WSIZE + (size_t)length * stride, 0, (size_t)removed * stride);
		if( array->reference_stride != 0 )
			hl_gc_clear_values(array->references + HL_WSIZE + (size_t)length * array->reference_stride * sizeof(void*),
				(size_t)removed * array->reference_stride * sizeof(void*), &hlt_dyn);
		for( int i = length; i < old_length; i++ ) realtime_value_array_set_valid(array, i, false);
	}
	array->array.size = length;
	realtime_value_array_sync(array);
}

/* Preserve both lanes and validity with memmove semantics, including overlapping moves within one array. */
static void realtime_value_array_move(realtime_value_array *target, int target_index, realtime_value_array *source, int source_index, int count) {
	if( count == 0 ) return;
	size_t stride = source->scalar_stride_bits / 8;
	if( stride != 0 )
		memmove(target->array.data + HL_WSIZE + (size_t)target_index * stride,
			source->array.data + HL_WSIZE + (size_t)source_index * stride, (size_t)count * stride);
	if( source->reference_stride != 0 )
		hl_gc_move_values(target->references + HL_WSIZE + (size_t)target_index * source->reference_stride * sizeof(void*),
			source->references + HL_WSIZE + (size_t)source_index * source->reference_stride * sizeof(void*),
			(size_t)count * source->reference_stride * sizeof(void*), &hlt_dyn);
	if( source->has_validity ) {
		if( target == source && target_index > source_index ) {
			for( int i = count; i-- > 0; ) realtime_value_array_set_valid(target, target_index + i, realtime_value_array_valid_at(source, source_index + i));
		} else {
			for( int i = 0; i < count; i++ ) realtime_value_array_set_valid(target, target_index + i, realtime_value_array_valid_at(source, source_index + i));
		}
	}
}

/* Remove an element in place without allocating the array that splice returns. */
HL_PRIM void HL_NAME(__value_array_remove_at)(varray *value, int index) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array_check_index(array, index);
	realtime_value_array_move(array, index, array, index + 1, array->array.size - index - 1);
	HL_NAME(__value_array_resize)(value, array->array.size - 1);
}

static realtime_value_array *realtime_value_array_new_like(realtime_value_array *array, int length) {
	realtime_value_array *result = (realtime_value_array*)HL_NAME(__value_array_alloc)(length, array->array.at, array->scalar_stride_bits,
		array->reference_stride, array->word_bits, array->has_validity);
	hl_gc_store_ref(&result->dynamic_read, array->dynamic_read, &hlt_dyn);
	hl_gc_store_ref(&result->dynamic_write, array->dynamic_write, &hlt_dyn);
	hl_gc_store_ref(&result->dynamic_accepts, array->dynamic_accepts, &hlt_dyn);
	return result;
}

/* Conversion may throw or run a collection; do not expose a partially written destination element. */
HL_PRIM void HL_NAME(__value_array_dynamic_store)(varray *value, int index, vdynamic *input) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( index < 0 || index == INT_MAX ) hl_error("Array index out of bounds");
	realtime_value_array *temporary = realtime_value_array_new_like(array, 1);
	HL_NAME(__value_array_dynamic_write)(&temporary->array, 0, input);
	HL_NAME(__value_array_ensure)(value, index);
	realtime_value_array_move(array, index, temporary, 0, 1);
}

HL_PRIM varray *HL_NAME(__value_array_copy)(varray *value) {
	realtime_value_array *array = realtime_value_array_require(value);
	int length = array->array.size;
	realtime_value_array *copy = realtime_value_array_new_like(array, length);
	realtime_value_array_move(copy, 0, array, 0, length);
	return &copy->array;
}

HL_PRIM varray *HL_NAME(__value_array_slice)(varray *value, int start, int end) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_array_slice_bounds(value, &start, &end);
	realtime_value_array *result = realtime_value_array_new_like(array, end - start);
	realtime_value_array_move(result, 0, array, start, end - start);
	return &result->array;
}

HL_PRIM varray *HL_NAME(__value_array_concat)(varray *left, varray *right) {
	realtime_value_array *a = realtime_value_array_require(left), *b = realtime_value_array_require(right);
	if( !HL_NAME(__value_array_compatible)(left, right) )
		hl_error("Incompatible inline value arrays");
	if( b->array.size > INT_MAX - a->array.size ) hl_error("Value array is too large");
	realtime_value_array *result = realtime_value_array_new_like(a, a->array.size + b->array.size);
	realtime_value_array_move(result, 0, a, 0, a->array.size);
	realtime_value_array_move(result, a->array.size, b, 0, b->array.size);
	return &result->array;
}

/** Insert an unwritten slot after evaluating the value to be inserted. */
HL_PRIM int HL_NAME(__value_array_insert_empty)(varray *value, int position) {
	realtime_value_array *array = realtime_value_array_require(value);
	int size = array->array.size;
	if( size == INT_MAX ) hl_error("Value array is too large");
	if( position < 0 ) position += size;
	if( position < 0 ) position = 0;
	if( position > size ) position = size;
	realtime_value_array_reserve(array, size + 1);
	array->array.size = size + 1;
	realtime_value_array_sync(array);
	realtime_value_array_move(array, position + 1, array, position, size - position);
	size_t stride = array->scalar_stride_bits / 8;
	if( stride != 0 ) memset(array->array.data + HL_WSIZE + (size_t)position * stride, 0, stride);
	if( array->reference_stride != 0 )
		hl_gc_clear_values(array->references + HL_WSIZE + (size_t)position * array->reference_stride * sizeof(void*),
			(size_t)array->reference_stride * sizeof(void*), &hlt_dyn);
	realtime_value_array_set_valid(array, position, false);
	return position;
}

/* Convert before moving the original elements, so an exception leaves every existing alias unchanged. */
HL_PRIM void HL_NAME(__value_array_dynamic_insert)(varray *value, int position, vdynamic *input) {
	realtime_value_array *array = realtime_value_array_require(value);
	realtime_value_array *temporary = realtime_value_array_new_like(array, 1);
	HL_NAME(__value_array_dynamic_write)(&temporary->array, 0, input);
	int inserted = HL_NAME(__value_array_insert_empty)(value, position);
	realtime_value_array_move(array, inserted, temporary, 0, 1);
}

HL_PRIM varray *HL_NAME(__value_array_splice)(varray *value, int position, int length) {
	realtime_value_array *array = realtime_value_array_require(value);
	if( length < 0 || position > array->array.size ) return &realtime_value_array_new_like(array, 0)->array;
	if( position < 0 ) {
		position += array->array.size;
		if( position < 0 ) position = 0;
	}
	if( length > array->array.size - position ) length = array->array.size - position;
	realtime_value_array *removed = realtime_value_array_new_like(array, length);
	realtime_value_array_move(removed, 0, array, position, length);
	realtime_value_array_move(array, position, array, position + length, array->array.size - position - length);
	HL_NAME(__value_array_resize)(value, array->array.size - length);
	return &removed->array;
}

HL_PRIM void HL_NAME(__value_array_reverse)(varray *value) {
	realtime_value_array *array = realtime_value_array_require(value);
	size_t stride = array->scalar_stride_bits / 8;
	for( int left = 0, right = array->array.size - 1; left < right; left++, right-- ) {
		vbyte *a = array->array.data + HL_WSIZE + (size_t)left * stride;
		vbyte *b = array->array.data + HL_WSIZE + (size_t)right * stride;
		for( size_t i = 0; i < stride; i++ ) { vbyte byte = a[i]; a[i] = b[i]; b[i] = byte; }
		if( array->reference_stride != 0 )
			hl_gc_swap_values(array->references + HL_WSIZE + (size_t)left * array->reference_stride * sizeof(void*),
				array->references + HL_WSIZE + (size_t)right * array->reference_stride * sizeof(void*),
				(size_t)array->reference_stride * sizeof(void*), &hlt_dyn);
		if( array->has_validity ) {
			bool left_valid = realtime_value_array_valid_at(array, left), right_valid = realtime_value_array_valid_at(array, right);
			realtime_value_array_set_valid(array, left, right_valid);
			realtime_value_array_set_valid(array, right, left_valid);
		}
	}
}
