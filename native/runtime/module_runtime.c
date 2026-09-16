HL_PRIM hl_runtime_module *HL_NAME(load)( vbyte *bytes, int length, vbyte *identity, int identity_length ) {
	hl_runtime_module *runtime = NULL;
	return hl_runtime_module_load(bytes,length,identity,identity_length,&runtime) == HL_RUNTIME_OK ? runtime : NULL;
}

HL_PRIM hl_runtime_module *HL_NAME(load_code)( vbyte *code, vbyte *bytes, int length, vbyte *identity, int identity_length ) {
	hl_runtime_module *runtime = NULL;
	return hl_runtime_module_load_code((hl_code*)code,bytes,length,identity,identity_length,&runtime) == HL_RUNTIME_OK ? runtime : NULL;
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_load_code)( vbyte *code, realtime_bytes *bytes, int length, realtime_bytes *identity, int identity_length ) {
	hl_runtime_module *runtime = NULL;
	return hl_runtime_module_load_code((hl_code*)code,bytes == NULL ? NULL : bytes->data,length,identity == NULL ? NULL : identity->data,identity_length,&runtime) == HL_RUNTIME_OK ? (vbyte*)runtime : NULL;
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_load_code_manifest)( vbyte *code, realtime_bytes *bytes, int length, realtime_bytes *module_id,
	int revision, int *stable_ids, int *slots, int identity_count, int initializer_slot ) {
	hl_runtime_module *runtime = NULL;
	return hl_runtime_module_load_code_manifest((hl_code*)code,bytes == NULL ? NULL : bytes->data,length,
		module_id == NULL ? NULL : module_id->data,module_id == NULL ? 0 : module_id->length,revision,stable_ids,slots,identity_count,initializer_slot,&runtime) == HL_RUNTIME_OK
		? (vbyte*)runtime : NULL;
}

HL_PRIM bool HL_NAME(native_runtime_module_unload)( vbyte *module ) {
	return module != NULL && hl_runtime_module_release((hl_runtime_module*)module) == HL_RUNTIME_OK;
}

HL_PRIM int HL_NAME(native_runtime_module_call_i32)( vbyte *module, int stable_id ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_i32((hl_runtime_module*)module,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime function call (status %d, stable ID %d)",status,stable_id);
	return result;
}

HL_PRIM void HL_NAME(native_runtime_module_call_void)( vbyte *module, int stable_id ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_void((hl_runtime_module*)module,stable_id,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime void call (status %d, stable ID %d)",status,stable_id);
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_call_bytes)( vbyte *module, int stable_id ) {
	vbyte *result = NULL;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes((hl_runtime_module*)module,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime string function call (status %d, stable ID %d)",status,stable_id);
	return result;
}

HL_PRIM void HL_NAME(native_runtime_module_call_bytes1)( vbyte *module, int stable_id, vbyte *argument ) {
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_bytes1((hl_runtime_module*)module,stable_id,argument,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime string argument function call (status %d, stable ID %d)",status,stable_id);
}

HL_PRIM vdynamic *HL_NAME(native_runtime_module_call_closure)( vbyte *module, int stable_id ) {
	vclosure *result = NULL;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_closure((hl_runtime_module*)module,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime closure function call (status %d, stable ID %d)",status,stable_id);
	return (vdynamic*)result;
}

HL_PRIM int HL_NAME(native_runtime_module_call_closure_i32)( vbyte *module, vclosure *closure ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_retained_closure_i32((hl_runtime_module*)module,closure,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime retained closure (status %d)",status);
	return result;
}

HL_PRIM vdynamic *HL_NAME(native_runtime_module_call_object)( vbyte *module, int stable_id ) {
	vdynamic *result = NULL, *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_object((hl_runtime_module*)module,stable_id,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime object function call (status %d, stable ID %d)",status,stable_id);
	return result;
}

HL_PRIM int HL_NAME(native_runtime_module_call_i32_object)( vbyte *module, int stable_id, vdynamic *argument ) {
	int result = 0;
	vdynamic *exception = NULL;
	hl_runtime_status status = hl_runtime_module_call_i32_object((hl_runtime_module*)module,stable_id,argument,&result,&exception);
	if( status == HL_RUNTIME_EXCEPTION ) realtime_raise_module_exception();
	if( status != HL_RUNTIME_OK ) hl_error("Invalid external runtime object argument call (status %d, stable ID %d)",status,stable_id);
	return result;
}

HL_PRIM int HL_NAME(native_runtime_module_validate_call)( vbyte *module, int stable_id, int shape ) {
	return hl_runtime_module_validate_call((hl_runtime_module*)module,stable_id,shape);
}

HL_PRIM int HL_NAME(native_runtime_module_type_count)( vbyte *module ) {
	return hl_runtime_module_type_count((hl_runtime_module*)module);
}

HL_PRIM int HL_NAME(native_runtime_module_type_capacity)( vbyte *module ) {
	return hl_runtime_module_type_capacity((hl_runtime_module*)module);
}

HL_PRIM int HL_NAME(native_runtime_module_live_allocation_count)( vbyte *module ) {
	return hl_runtime_module_live_allocation_count((hl_runtime_module*)module);
}

HL_PRIM int HL_NAME(native_runtime_module_native_root_count)( vbyte *module ) {
	return hl_runtime_module_native_root_count((hl_runtime_module*)module);
}

HL_PRIM void HL_NAME(native_runtime_module_retirement_status)( vbyte *module, vbyte *out ) {
	hl_module_retirement_status status;
	int fields[4];
	if( out == NULL ) return;
	hl_runtime_module_retirement_status_get((hl_runtime_module*)module,&status);
	fields[0] = status.live_managed_allocations;
	fields[1] = status.owned_native_roots;
	fields[2] = status.registry_readers;
	fields[3] = status.flags;
	memcpy(out,fields,sizeof(fields));
}

HL_PRIM int HL_NAME(native_runtime_module_revision)( vbyte *module ) {
	return hl_runtime_module_revision((hl_runtime_module*)module);
}

HL_PRIM int HL_NAME(native_runtime_module_patch)( vbyte *module, realtime_bytes *bytes, int length ) {
	return (int)hl_runtime_module_apply_hlp((hl_runtime_module*)module,bytes == NULL ? NULL : bytes->data,length);
}

HL_PRIM void HL_NAME(native_runtime_module_set_patch_failure_stage)( vbyte *module, int stage ) {
	if( module != NULL ) hl_runtime_module_set_patch_failure_stage((hl_runtime_module*)module,stage);
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_patch_code)( vbyte *module, realtime_bytes *bytes, int length, vbyte *status_out ) {
	hl_patch_code *code = NULL;
	hl_runtime_status status = hl_runtime_module_apply_hlp_capture((hl_runtime_module*)module,bytes == NULL ? NULL : bytes->data,length,&code);
	if( status_out != NULL ) memcpy(status_out,&status,sizeof(status));
	return (vbyte*)code;
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_patch_code_haxe_types)( vbyte *module, realtime_bytes *bytes, int length, int type_count, vbyte *status_out ) {
	hl_patch_code *code = NULL;
	hl_runtime_status status = hl_runtime_module_apply_hlp_capture_types((hl_runtime_module*)module,bytes == NULL ? NULL : bytes->data,length,type_count,&code);
	if( status_out != NULL ) memcpy(status_out,&status,sizeof(status));
	return (vbyte*)code;
}

HL_PRIM vbyte *HL_NAME(native_runtime_module_patch_code_haxe_metadata)( vbyte *module, vbyte *input, int type_count,
	vbyte *functions, int function_count, vbyte *pools, vbyte *debug, vbyte *status_out ) {
	hl_patch_code *code = NULL;
	hl_runtime_status status = hl_runtime_module_apply_hlp_capture_metadata_input((hl_runtime_module*)module,(hl_patch_input*)input,
		type_count,(hl_function*)functions,function_count,(hl_patch_pools*)pools,(hl_patch_debug*)debug,&code);
	if( status_out != NULL ) memcpy(status_out,&status,sizeof(status));
	return (vbyte*)code;
}

HL_PRIM bool HL_NAME(native_runtime_module_release_code)( vbyte *code ) {
	return hl_patch_code_release((hl_patch_code*)code);
}

HL_PRIM int HL_NAME(native_runtime_module_code_revision)( vbyte *code ) {
	return hl_patch_code_revision((hl_patch_code*)code);
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

HL_PRIM hl_patch_code *HL_NAME(patch_code)( hl_runtime_module *runtime, vbyte *bytes, int length, vbyte *status_out ) {
	hl_patch_code *code = NULL;
	hl_runtime_status status = hl_runtime_module_apply_hlp_capture(runtime,bytes,length,&code);
	if( status_out != NULL ) memcpy(status_out,&status,sizeof(status));
	return code;
}

HL_PRIM bool HL_NAME(release_code)( hl_patch_code *code ) {
	return hl_patch_code_release(code);
}

HL_PRIM int HL_NAME(code_revision)( hl_patch_code *code ) {
	return hl_patch_code_revision(code);
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
