#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>
#include <string.h>

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
