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

HL_PRIM vbyte *HL_NAME(jit_location)( hl_runtime_module *runtime, int stable_id ) {
	const char *location = hl_runtime_module_resolve_jit_location(runtime,stable_id);
	int length;
	vbyte *bytes;
	if( location == NULL ) return NULL;
	length = (int)strlen(location);
	bytes = (vbyte*)hl_gc_alloc_noptr((length + 1) * 2);
	for(int i=0;i<length;i++) {
		bytes[i * 2] = (vbyte)location[i];
		bytes[i * 2 + 1] = 0;
	}
	bytes[length * 2] = 0;
	bytes[length * 2 + 1] = 0;
	return bytes;
}

HL_PRIM int HL_NAME(debug_region_count)( hl_runtime_module *runtime ) {
	return hl_runtime_module_debug_region_count(runtime);
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

HL_PRIM void HL_NAME(retirement_status)( hl_runtime_module *runtime, vbyte *out ) {
	hl_module_retirement_status status;
	int fields[4];
	if( out == NULL ) return;
	hl_runtime_module_retirement_status_get(runtime,&status);
	fields[0] = status.live_managed_allocations;
	fields[1] = status.owned_native_roots;
	fields[2] = status.registry_readers;
	fields[3] = status.flags;
	memcpy(out,fields,sizeof(fields));
}

HL_PRIM int HL_NAME(revision)( hl_runtime_module *runtime ) {
	return hl_runtime_module_revision(runtime);
}

HL_PRIM void HL_NAME(set_patch_failure_stage)( hl_runtime_module *runtime, int stage ) {
	hl_runtime_module_set_patch_failure_stage(runtime,stage);
}

HL_PRIM int HL_NAME(dispose)( hl_runtime_module *runtime ) {
	return hl_runtime_module_release(runtime);
}

HL_PRIM int HL_NAME(retry_failed_retirements)() {
	return hl_runtime_failed_retirements_retry();
}

HL_PRIM int HL_NAME(failed_retirement_count)() {
	return hl_runtime_failed_retirements_count();
}
