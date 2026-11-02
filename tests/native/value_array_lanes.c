#include <hl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern varray *realtime___value_array_alloc(int, hl_type*, int, int, int, bool);
extern bool realtime___value_array_is(varray*);
extern void realtime___value_array_ensure(varray*, int);
extern void realtime___value_array_validate(varray*, int);
extern bool realtime___value_array_is_initialized(varray*, int);
extern void realtime___value_array_mark(varray*, int);
extern void realtime___value_array_clear(varray*, int);
extern void realtime___value_array_clear_ref(varray*, int, int);
extern void realtime___value_array_set_bridge(varray*, vclosure*, vclosure*, vclosure*);
extern varray *realtime___value_array_retype(varray*, hl_type*, int, int, int, bool, vclosure*, vclosure*, vclosure*);
extern int realtime___value_array_read_i32(varray*, int, int, int, bool);
extern int64_t realtime___value_array_read_i64(varray*, int, int, int, bool);
extern void realtime___value_array_write_i32(varray*, int, int, int, int);
extern void realtime___value_array_write_i64(varray*, int, int, int, int64_t);
extern bool realtime___value_array_read_bool(varray*, int, int);
extern void realtime___value_array_write_bool(varray*, int, int, bool);
extern vbyte *realtime___value_array_read_ptr(varray*, int, int, int);
extern void realtime___value_array_write_ptr(varray*, int, int, int, vbyte*);
extern hl_type *realtime___value_array_read_type(varray*, int, int, int);
extern void realtime___value_array_write_type(varray*, int, int, int, hl_type*);
extern float realtime___value_array_read_f32(varray*, int, int);
extern double realtime___value_array_read_f64(varray*, int, int);
extern void realtime___value_array_write_f32(varray*, int, int, float);
extern void realtime___value_array_write_f64(varray*, int, int, double);
extern vdynamic *realtime___value_array_read_ref(varray*, int, int);
extern void realtime___value_array_write_ref(varray*, int, int, vdynamic*);
extern void realtime___value_array_resize(varray*, int);
extern varray *realtime___value_array_copy(varray*);
extern varray *realtime___value_array_slice(varray*, int, int);
extern varray *realtime___value_array_concat(varray*, varray*);
extern int realtime___value_array_insert_empty(varray*, int);
extern varray *realtime___value_array_splice(varray*, int, int);
extern void realtime___value_array_reverse(varray*);
extern varray *realtime___array_copy_any(varray*);
extern varray *realtime___array_concat_any(varray*, varray*);
extern varray *realtime___array_slice_any(varray*, int, int);
extern varray *realtime___array_splice_any(varray*, int, int);
extern void realtime___array_reverse_any(varray*);
extern void realtime___array_resize_any(varray*, int);
extern vdynamic *realtime___array_get_any(varray*, int);
extern void realtime___array_set_any(varray*, int, vdynamic*);
extern int realtime___array_push_any(varray*, vdynamic*);
extern void realtime___array_insert_any(varray*, int, vdynamic*);
extern void hl_gc_stats(double*, double*, double*);
extern void hl_gc_enable(bool);
extern void hl_gc_set_profile_allocation_callback(void (*)(hl_type*, int, int, void*));

static hl_runtime_obj value_layout = { .size = sizeof(int), .hasPtr = false };
static hl_module_context value_module;
static hl_type_obj value_object = { .m = &value_module, .rt = &value_layout };
static hl_type value_type = { .kind = HSTRUCT, .obj = &value_object };
static varray *values, *copy, *bridge_array, *optional_gc;
static void *large, *hidden_target;
static int finalized, reference_verified, observed_allocations, observed_value_boxes;
static int capture_no_stack(void **stack, int size) { (void)stack; (void)size; return 0; }
static vdynamic *bridge_read(varray *array, int index) {
	int value = realtime___value_array_read_i32(array, index, 0, 32, true);
	return hl_make_dyn(&value, &hlt_i32);
}

static void bridge_write(varray *array, int index, vdynamic *value) {
	int input = value->t == &value_type ? *(int*)value->v.ptr : value->v.i;
	realtime___value_array_ensure(array, index);
	realtime___value_array_write_i32(array, index, 0, 32, input);
	if( input == 777 ) hl_error("probe bridge write");
	realtime___value_array_mark(array, index);
}

static bool bridge_accepts(vdynamic *value) { return value != NULL && (value->t == &hlt_i32 || value->t == &value_type); }
static vclosure static_read_bridge = { .fun = (void*)bridge_read };
static vclosure static_write_bridge = { .fun = (void*)bridge_write };
static vclosure static_accepts_bridge = { .fun = (void*)bridge_accepts };

static bool rejects_dynamic_insert(varray *array, vdynamic *value) {
	hl_trap_ctx trap;
	vdynamic *error = NULL;
	hl_trap(trap, error, rejected);
	realtime___array_insert_any(array, 0, value);
	hl_endtrap(trap);
	return false;
rejected:
	hl_endtrap(trap);
	return error != NULL;
}

static bool rejects_dynamic_store(varray *array, int index, vdynamic *value) {
	hl_trap_ctx trap;
	vdynamic *error = NULL;
	hl_trap(trap, error, rejected);
	realtime___array_set_any(array, index, value);
	hl_endtrap(trap);
	return false;
rejected:
	hl_endtrap(trap);
	return error != NULL;
}

static bool rejects_dynamic_retype(varray *array) {
	hl_trap_ctx trap;
	vdynamic *error = NULL;
	hl_trap(trap, error, rejected);
	realtime___value_array_retype(array, &value_type, 32, 0, 32, true,
		&static_read_bridge, &static_write_bridge, &static_accepts_bridge);
	hl_endtrap(trap);
	return false;
rejected:
	hl_endtrap(trap);
	return error != NULL;
}

/* Keep the only references to the closures in the array header, not on the test's conservative stack. */
static void *install_bridges(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	vclosure *read = hl_gc_alloc_noptr(sizeof(vclosure)), *write = hl_gc_alloc_noptr(sizeof(vclosure)),
		*accepts = hl_gc_alloc_noptr(sizeof(vclosure));
	memset(read, 0, sizeof(*read)); memset(write, 0, sizeof(*write)); memset(accepts, 0, sizeof(*accepts));
	read->fun = (void*)bridge_read; write->fun = (void*)bridge_write; accepts->fun = (void*)bridge_accepts;
	realtime___value_array_set_bridge(bridge_array, read, write, accepts);
	hl_unregister_thread();
	return NULL;
}

static void finalize(void *value) { (void)value; finalized++; }

static void count_allocation(hl_type *type, int requested, int allocated, void *caller) {
	(void)requested; (void)allocated; (void)caller;
	observed_allocations++;
	if( type == &value_type ) observed_value_boxes++;
}

/* A separate thread leaves no conservative stack root for the object whose only owner is the reference lane. */
static void *prepare_reference(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	void **target = hl_gc_alloc_gen(NULL, 3 * sizeof(void*), MEM_KIND_FINALIZER | MEM_ZERO);
	target[0] = (void*)finalize;
	target[2] = (void*)(size_t)123;
	hidden_target = target;
	hl_unregister_thread();
	return NULL;
}

static void *install_reference_and_grow(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	realtime___value_array_write_ref(values, 0, 0, (vdynamic*)hidden_target);
	realtime___value_array_ensure(values, 1999);
	hl_unregister_thread();
	return NULL;
}

static void *install_optional_reference(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	realtime___value_array_write_ref(optional_gc, 1, 0, (vdynamic*)hidden_target);
	hidden_target = NULL;
	hl_unregister_thread();
	return NULL;
}

static void *clear_optional_reference(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	realtime___value_array_clear_ref(optional_gc, 1, 0);
	hl_unregister_thread();
	return NULL;
}

static void *verify_reference(void *unused) {
	int marker = 0;
	(void)unused;
	hl_register_thread(&marker);
	void **target = (void**)realtime___value_array_read_ref(copy, 0, 0);
	reference_verified = target == hidden_target && target[2] == (void*)(size_t)123;
	hl_unregister_thread();
	return NULL;
}

static int worker(void *(*function)(void*)) {
	pthread_t thread;
	if( pthread_create(&thread, NULL, function, NULL) != 0 ) return 0;
	hl_blocking(true);
	pthread_join(thread, NULL);
	hl_blocking(false);
	return 1;
}

int main(void) {
	int marker = 0;
	hl_global_init();
	/* The standalone probe has no HashLink VM to install an exception stack capturer. */
	hl_setup.capture_stack = capture_no_stack;
	hl_register_thread(&marker);
	hl_gc_enable(false);
	hl_add_root(&values);
	hl_add_root(&copy);
	hl_add_root(&bridge_array);
	hl_add_root(&optional_gc);
	hl_add_root(&large);
	values = realtime___value_array_alloc(0, &value_type, 24, 1, 32, true);
	if( !realtime___value_array_is(values) || !hl_same_type(values->t, &hlt_array) || !hl_safe_cast(values->t, &hlt_array) ) return 1;
	if( values->size != 0 || values->capacity != 0 || values->data != NULL ) return 1;
	realtime___value_array_ensure(values, 998);
	if( realtime___value_array_is_initialized(values, 0) || values->size != 999 ) return 2;

	double before_bytes, before_count, before_heap, after_bytes, after_count, after_heap;
	hl_gc_stats(&before_bytes, &before_count, &before_heap);
	observed_allocations = observed_value_boxes = 0;
	hl_gc_set_profile_allocation_callback(count_allocation);
	for( int i = 0; i < 999; i++ ) {
		realtime___value_array_write_i32(values, i, 0, 8, i & 255);
		realtime___value_array_write_i32(values, i, 8, 16, -i);
		realtime___value_array_write_ref(values, i, 0, NULL);
		realtime___value_array_mark(values, i);
	}
	for( int i = 0; i < 999; i++ )
		if( realtime___value_array_read_i32(values, i, 0, 8, false) != (i & 255)
			|| realtime___value_array_read_i32(values, i, 8, 16, true) != -i
			|| realtime___value_array_read_ref(values, i, 0) != NULL ) return 3;
	hl_gc_set_profile_allocation_callback(NULL);
	hl_gc_stats(&after_bytes, &after_count, &after_heap);
	if( before_count != after_count || before_bytes != after_bytes || observed_allocations != 0 ) return 4;
	varray *growth = realtime___value_array_alloc(0, &value_type, 24, 1, 32, true);
	hl_add_root(&growth);
	observed_allocations = observed_value_boxes = 0;
	hl_gc_set_profile_allocation_callback(count_allocation);
	for( int i = 0; i < 5000; i++ ) {
		realtime___value_array_ensure(growth, i);
		realtime___value_array_write_i32(growth, i, 0, 8, i & 255);
		realtime___value_array_write_i32(growth, i, 8, 16, -i);
		realtime___value_array_mark(growth, i);
	}
	hl_gc_set_profile_allocation_callback(NULL);
	int growth_allocations = observed_allocations;
	if( observed_value_boxes != 0 || growth_allocations > 128
		|| realtime___value_array_read_i32(growth, 4999, 8, 16, true) != -4999 ) return 21;
	hl_remove_root(&growth);
	varray *slice = realtime___array_slice_any(values, -4, -1);
	hl_add_root(&slice);
	if( slice->size != 3 || realtime___value_array_read_i32(slice, 0, 8, 16, true) != -995
		|| realtime___value_array_read_i32(slice, 2, 8, 16, true) != -997 ) return 14;
	varray *joined = realtime___array_concat_any(slice, slice);
	hl_add_root(&joined);
	realtime___array_reverse_any(joined);
	varray *removed = realtime___array_splice_any(joined, 1, 3);
	hl_add_root(&removed);
	if( joined->size != 3 || removed->size != 3 || realtime___value_array_read_i32(joined, 0, 8, 16, true) != -997
		|| realtime___value_array_read_i32(joined, 1, 8, 16, true) != -996
		|| realtime___value_array_read_i32(removed, 0, 8, 16, true) != -996
		|| realtime___value_array_read_i32(removed, 2, 8, 16, true) != -997 ) return 15;
	if( realtime___value_array_insert_empty(joined, 1) != 1 || realtime___value_array_is_initialized(joined, 1)
		|| realtime___value_array_read_i32(joined, 2, 8, 16, true) != -996 ) return 16;
	realtime___value_array_write_i32(joined, 1, 0, 8, 7);
	realtime___value_array_write_i32(joined, 1, 8, 16, -7);
	realtime___value_array_mark(joined, 1);
	if( realtime___value_array_read_i32(joined, 1, 8, 16, true) != -7 ) return 17;
	realtime___value_array_clear(joined, 1);
	if( realtime___value_array_is_initialized(joined, 1)
		|| realtime___value_array_read_i32(joined, 0, 8, 16, true) != -997
		|| realtime___value_array_read_i32(joined, 2, 8, 16, true) != -996 ) return 24;
	hl_remove_root(&removed);
	hl_remove_root(&joined);
	hl_remove_root(&slice);

	large = hl_gc_alloc_gen(NULL, 16 << 20, MEM_KIND_RAW | MEM_ZERO);
	if( !worker(prepare_reference) ) return 5;
	bool incremental = hl_gc_incremental_supported();
	if( getenv("HL_GC_INCREMENTAL_TEST_SOFTWARE") != NULL && !incremental ) return 13;
	if( incremental && (hl_gc_step(0.001) || !hl_gc_incremental_pending()) ) return 5;
	/* Reallocate both lanes after the reference was installed, including during an incremental mark when supported. */
	if( !worker(install_reference_and_grow) ) return 5;
	if( incremental ) {
		int slices = 0;
		while( !hl_gc_step(1000.0) ) if( ++slices > 10000 ) return 5;
	}
	if( !realtime___value_array_is_initialized(values, 998)
		|| realtime___value_array_is_initialized(values, 999) ) return 6;
	varray *partial = realtime___value_array_slice(values, 998, 1001);
	hl_add_root(&partial);
	if( !realtime___value_array_is_initialized(partial, 0) || realtime___value_array_is_initialized(partial, 1)
		|| realtime___value_array_is_initialized(partial, 2) ) return 6;
	if( realtime___value_array_insert_empty(partial, 0) != 0 || realtime___value_array_is_initialized(partial, 0)
		|| !realtime___value_array_is_initialized(partial, 1) || realtime___value_array_is_initialized(partial, 2) ) return 6;
	realtime___value_array_reverse(partial);
	if( !realtime___value_array_is_initialized(partial, 2) || realtime___value_array_is_initialized(partial, 3) ) return 6;
	hl_remove_root(&partial);
	hl_gc_major();
	if( finalized != 0 ) return 6;
	copy = realtime___array_copy_any(values);
	if( !realtime___value_array_is_initialized(copy, 998)
		|| realtime___value_array_is_initialized(copy, 999) ) return 7;
	if( !worker(verify_reference) || !reference_verified ) return 7;
	realtime___value_array_write_i32(values, 7, 8, 16, 1234);
	if( realtime___value_array_read_i32(copy, 7, 8, 16, true) != -7
		|| realtime___value_array_read_i32(values, 7, 8, 16, true) != 1234 ) return 7;
	realtime___array_resize_any(values, 0);
	hl_gc_major();
	if( finalized != 0 ) return 8;
	realtime___value_array_resize(copy, 0);
	hidden_target = NULL;
	large = NULL;
	for( int i = 0; i < 4; i++ ) hl_gc_major();
	if( finalized != 1 ) return 9;
	realtime___value_array_resize(values, 1);
	if( realtime___value_array_is_initialized(values, 0) ) return 10;

	varray *floats = realtime___value_array_alloc(1, &value_type, 96, 0, 64, true);
	hl_add_root(&floats);
	realtime___value_array_write_f32(floats, 0, 0, -0.0f);
	realtime___value_array_write_f64(floats, 0, 32, 1.25);
	realtime___value_array_mark(floats, 0);
	float f = realtime___value_array_read_f32(floats, 0, 0);
	uint32_t f_bits = 0;
	memcpy(&f_bits, &f, sizeof(f_bits));
	if( f_bits != 0x80000000u || realtime___value_array_read_f64(floats, 0, 32) != 1.25 ) return 11;
	realtime___value_array_write_i64(floats, 0, 32, 32, INT64_C(0x1ffffffff));
	if( realtime___value_array_read_i64(floats, 0, 32, 32, true) != -1
		|| realtime___value_array_read_i64(floats, 0, 32, 32, false) != INT64_C(0xffffffff) ) return 12;
	realtime___value_array_write_ptr(floats, 0, 32, 32, (vbyte*)(uintptr_t)0x1234);
	if( (uintptr_t)realtime___value_array_read_ptr(floats, 0, 32, 32) != 0x1234 ) return 22;
	if( sizeof(uintptr_t) == 8 ) {
		realtime___value_array_write_ptr(floats, 0, 32, 64, (vbyte*)(uintptr_t)UINT64_C(0x123456789));
		if( (uint64_t)(uintptr_t)realtime___value_array_read_ptr(floats, 0, 32, 64) != UINT64_C(0x123456789) ) return 22;
	}
	realtime___value_array_write_type(floats, 0, 32, sizeof(void*) * 8, &value_type);
	if( realtime___value_array_read_type(floats, 0, 32, sizeof(void*) * 8) != &value_type ) return 40;
	varray *optionals = realtime___value_array_alloc(2, &value_type, 32, 1, 32, false);
	hl_add_root(&optionals);
	if( !realtime___value_array_is_initialized(optionals, 0) || realtime___value_array_read_bool(optionals, 0, 0) ) return 18;
	realtime___value_array_write_bool(optionals, 1, 0, true);
	realtime___value_array_write_i32(optionals, 1, 8, 16, 456);
	if( !realtime___value_array_read_bool(optionals, 1, 0)
		|| realtime___value_array_read_i32(optionals, 1, 8, 16, true) != 456 ) return 19;
	realtime___value_array_write_ref(optionals, 1, 0, (vdynamic*)optionals);
	realtime___value_array_clear(optionals, 1);
	if( realtime___value_array_read_bool(optionals, 1, 0)
		|| realtime___value_array_read_i32(optionals, 1, 8, 16, true) != 0
		|| realtime___value_array_read_ref(optionals, 1, 0) != NULL ) return 23;
	realtime___value_array_write_bool(optionals, 1, 0, true);
	realtime___value_array_resize(optionals, 0);
	realtime___value_array_resize(optionals, 2);
	if( realtime___value_array_read_bool(optionals, 1, 0) ) return 20;
	optional_gc = optionals;
	if( !worker(prepare_reference) || !worker(install_optional_reference) ) return 41;
	hl_gc_major();
	if( finalized != 1 || !worker(clear_optional_reference) ) return 41;
	for( int i = 0; i < 4; i++ ) hl_gc_major();
	if( finalized != 2 ) return 42;
	optional_gc = NULL;
	bridge_array = realtime___value_array_alloc(2, &value_type, 32, 0, 32, true);
	if( !worker(install_bridges) ) return 25;
	hl_gc_major();
	if( realtime___array_get_any(bridge_array, 0) != NULL ) return 25;
	vdynamic input = { .t = &hlt_i32, .v.i = 17 };
	realtime___array_set_any(bridge_array, 0, &input);
	input.v.i = 23;
	if( realtime___array_push_any(bridge_array, &input) != 3 ) return 26;
	input.v.i = 31;
	realtime___array_insert_any(bridge_array, 1, &input);
	vdynamic invalid = { .t = &hlt_bool, .v.b = true };
	if( !rejects_dynamic_insert(bridge_array, &invalid) || bridge_array->size != 4
		|| realtime___array_get_any(bridge_array, 0)->v.i != 17 ) return 29;
	vdynamic throwing = { .t = &hlt_i32, .v.i = 777 };
	if( !rejects_dynamic_store(bridge_array, 0, &throwing) || bridge_array->size != 4
		|| realtime___array_get_any(bridge_array, 0)->v.i != 17
		|| !rejects_dynamic_store(bridge_array, 20, &throwing) || bridge_array->size != 4 ) return 39;
	if( !rejects_dynamic_insert(bridge_array, &throwing) || bridge_array->size != 4
		|| realtime___array_get_any(bridge_array, 0)->v.i != 17
		|| realtime___array_get_any(bridge_array, 1)->v.i != 31
		|| realtime___array_get_any(bridge_array, 2) != NULL
		|| realtime___array_get_any(bridge_array, 3)->v.i != 23 ) return 37;
	varray *dynamic_copy = realtime___array_copy_any(bridge_array);
	hl_add_root(&dynamic_copy);
	bridge_array = NULL;
	hl_gc_major();
	if( realtime___array_get_any(dynamic_copy, 0)->v.i != 17
		|| realtime___array_get_any(dynamic_copy, 1)->v.i != 31
		|| realtime___array_get_any(dynamic_copy, 2) != NULL
		|| realtime___array_get_any(dynamic_copy, 3)->v.i != 23 ) return 27;
	varray *ordinary = hl_alloc_array(&hlt_i32, 1);
	hl_add_root(&ordinary);
	hl_aptr(ordinary, int)[0] = 99;
	varray *mixed = realtime___array_concat_any(dynamic_copy, ordinary);
	hl_add_root(&mixed);
	if( mixed->at != &hlt_dyn || mixed->size != 5 || hl_aptr(mixed, vdynamic*)[2] != NULL
		|| hl_aptr(mixed, vdynamic*)[0]->v.i != 17 || hl_aptr(mixed, vdynamic*)[1]->v.i != 31
		|| hl_aptr(mixed, vdynamic*)[3]->v.i != 23 || hl_aptr(mixed, vdynamic*)[4]->v.i != 99 ) return 28;
	hl_remove_root(&mixed);
	hl_remove_root(&ordinary);
	bridge_array = realtime___value_array_alloc(0, &value_type, 64, 0, 64, true);
	if( !worker(install_bridges) ) return 30;
	input.v.i = 77;
	realtime___array_push_any(bridge_array, &input);
	varray *mixed_lanes = realtime___array_concat_any(dynamic_copy, bridge_array);
	hl_add_root(&mixed_lanes);
	if( mixed_lanes->at != &hlt_dyn || mixed_lanes->size != 5
		|| hl_aptr(mixed_lanes, vdynamic*)[0]->v.i != 17 || hl_aptr(mixed_lanes, vdynamic*)[4]->v.i != 77 ) return 30;
	hl_remove_root(&mixed_lanes);
	bridge_array = NULL;
	hl_remove_root(&dynamic_copy);
	varray *dynamic_source = hl_alloc_array(&hlt_dyn, 3);
	hl_add_root(&dynamic_source);
	int initial = 42;
	vdynamic *boxed = hl_make_dyn(&initial, &hlt_i32);
	hl_gc_store_ref(&hl_aptr(dynamic_source, vdynamic*)[0], boxed, &hlt_dyn);
	varray *alias = dynamic_source;
	if( realtime___value_array_retype(dynamic_source, &value_type, 32, 0, 32, true,
		&static_read_bridge, &static_write_bridge, &static_accepts_bridge) != alias
		|| !realtime___value_array_is(alias) || alias->size != 3
		|| realtime___array_get_any(alias, 0)->v.i != 42 || realtime___array_get_any(alias, 1) != NULL ) return 31;
	input.v.i = 64;
	if( realtime___array_push_any(alias, &input) != 4 || dynamic_source->size != 4
		|| realtime___array_get_any(dynamic_source, 3)->v.i != 64 ) return 32;
	for( int i = 0; i < 64; i++ ) realtime___array_push_any(alias, &input);
	if( dynamic_source->size != 68 || realtime___array_get_any(dynamic_source, 67)->v.i != 64 ) return 32;
	varray *converted_copy = realtime___array_copy_any(alias);
	hl_add_root(&converted_copy);
	hl_gc_major();
	if( realtime___array_get_any(converted_copy, 0)->v.i != 42
		|| realtime___array_get_any(converted_copy, 3)->v.i != 64 ) return 33;
	hl_remove_root(&converted_copy);
	varray *removed_from_alias = realtime___array_splice_any(alias, 1, 2);
	hl_add_root(&removed_from_alias);
	if( dynamic_source->size != 66 || removed_from_alias->size != 2
		|| realtime___array_get_any(dynamic_source, 1)->v.i != 64 ) return 35;
	realtime___array_resize_any(alias, 2);
	realtime___array_resize_any(dynamic_source, 10);
	if( alias->size != 10 || realtime___array_get_any(alias, 2) != NULL ) return 35;
	realtime___array_insert_any(alias, 1, &input);
	if( dynamic_source->size != 11 || realtime___array_get_any(dynamic_source, 1)->v.i != 64 ) return 35;
	if( !rejects_dynamic_insert(alias, &throwing) || dynamic_source->size != 11 || alias->size != 11
		|| realtime___array_get_any(dynamic_source, 0)->v.i != 42
		|| realtime___array_get_any(alias, 1)->v.i != 64
		|| realtime___array_get_any(dynamic_source, 3) != NULL ) return 38;
	hl_remove_root(&removed_from_alias);
	hl_remove_root(&dynamic_source);
	varray *invalid_source = hl_alloc_array(&hlt_dyn, 1);
	hl_add_root(&invalid_source);
	bool true_value = true;
	boxed = hl_make_dyn(&true_value, &hlt_bool);
	hl_gc_store_ref(&hl_aptr(invalid_source, vdynamic*)[0], boxed, &hlt_dyn);
	vbyte *old_data = invalid_source->data;
	if( !rejects_dynamic_retype(invalid_source) || invalid_source->at != &hlt_dyn
		|| invalid_source->data != old_data || invalid_source->size != 1
		|| !hl_aptr(invalid_source, vdynamic*)[0]->v.b ) return 34;
	hl_remove_root(&invalid_source);
	varray *throwing_source = hl_alloc_array(&hlt_dyn, 2);
	hl_add_root(&throwing_source);
	initial = 1;
	boxed = hl_make_dyn(&initial, &hlt_i32);
	hl_gc_store_ref(&hl_aptr(throwing_source, vdynamic*)[0], boxed, &hlt_dyn);
	initial = 777;
	boxed = hl_make_dyn(&initial, &hlt_i32);
	hl_gc_store_ref(&hl_aptr(throwing_source, vdynamic*)[1], boxed, &hlt_dyn);
	old_data = throwing_source->data;
	if( !rejects_dynamic_retype(throwing_source) || throwing_source->at != &hlt_dyn
		|| throwing_source->data != old_data || throwing_source->size != 2
		|| hl_aptr(throwing_source, vdynamic*)[0]->v.i != 1
		|| hl_aptr(throwing_source, vdynamic*)[1]->v.i != 777 ) return 36;
	hl_remove_root(&throwing_source);
	varray *native_source = hl_alloc_array(&value_type, 1);
	hl_add_root(&native_source);
	int *native_value = hl_gc_alloc_noptr(sizeof(int));
	*native_value = 53;
	hl_gc_store_ref(&hl_aptr(native_source, void*)[0], native_value, &value_type);
	varray *lane_source = realtime___value_array_alloc(0, &value_type, 32, 0, 32, true);
	hl_add_root(&lane_source);
	realtime___value_array_set_bridge(lane_source, &static_read_bridge, &static_write_bridge, &static_accepts_bridge);
	input.v.i = 8;
	realtime___array_push_any(lane_source, &input);
	varray *native_mix = realtime___array_concat_any(lane_source, native_source);
	hl_add_root(&native_mix);
	vdynamic *native_box = hl_aptr(native_mix, vdynamic*)[1];
	if( native_mix->at != &hlt_dyn || native_mix->size != 2 || native_box == NULL
		|| native_box->t != &value_type || *(int*)native_box->v.ptr != 53 ) return 38;
	*native_value = 54;
	if( *(int*)native_box->v.ptr != 53 ) return 39;
	hl_remove_root(&native_mix);
	hl_remove_root(&lane_source);
	if( realtime___value_array_retype(native_source, &value_type, 32, 0, 32, true,
		&static_read_bridge, &static_write_bridge, &static_accepts_bridge) != native_source
		|| realtime___array_get_any(native_source, 0)->v.i != 54 ) return 37;
	hl_remove_root(&native_source);
	hl_remove_root(&optionals);
	hl_remove_root(&floats);
	hl_remove_root(&values);
	hl_remove_root(&copy);
	hl_remove_root(&bridge_array);
	hl_remove_root(&optional_gc);
	hl_remove_root(&large);
	hl_unregister_thread();
	hl_global_free();
	printf("PASS: inline value lanes store 5000 elements with %d growth allocations and no element boxes\n", growth_allocations);
	return 0;
}
