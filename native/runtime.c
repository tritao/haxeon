#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>

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
