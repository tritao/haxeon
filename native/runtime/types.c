HL_PRIM int HL_NAME(native_pointer_size)() {
	return (int)sizeof(void*);
}

HL_PRIM void HL_NAME(native_metadata_publish_object_prototype)( hl_type *type ) {
	if( type == NULL || type->obj == NULL || type->obj->m == NULL )
		hl_error("HashLink object metadata publication requires an initialized object context");
	hl_get_obj_proto(type);
}

static hl_function *native_metadata_find_function( hl_function *functions, int count, int findex ) {
	int i;
	for( i = 0; i < count; i++ )
		if( functions[i].findex == findex ) return functions + i;
	return NULL;
}

HL_PRIM vbyte * HL_NAME(native_metadata_module_alloc)( hl_code *code ) {
	if( code == NULL )
		hl_error("HashLink native module allocation requires a code record");
	return (vbyte*)hl_module_alloc(code);
}

HL_PRIM bool HL_NAME(native_metadata_module_init)( vbyte *module, int flags ) {
	if( module == NULL )
		hl_error("HashLink native module initialization requires a module");
	return hl_module_init((hl_module*)module,flags | HL_MODULE_HAXE_METADATA) != 0;
}

HL_PRIM bool HL_NAME(native_metadata_module_initialize_constant)( vbyte *module, int index ) {
	if( module == NULL )
		hl_error("HashLink native constant initialization requires a module");
	return hl_module_init_constant((hl_module*)module,index) != 0;
}

HL_PRIM bool HL_NAME(native_metadata_module_unload)( vbyte *module ) {
	bool unloaded;
	if( module == NULL ) return false;
	unloaded = hl_module_unload((hl_module*)module) != 0;
	if( unloaded ) haxeon_gc_handle_detach_owner(module);
	return unloaded;
}

HL_PRIM bool HL_NAME(native_metadata_module_patch_generation)( vbyte *target, vbyte *generation ) {
	if( target == NULL || generation == NULL )
		hl_error("HashLink native module patch requires two modules");
	return hl_module_patch_generation((hl_module*)target,(hl_module*)generation) != 0;
}

HL_PRIM bool HL_NAME(native_metadata_module_patch_slots)( vbyte *target, vbyte *generation, int *indices, int count ) {
	if( target == NULL || generation == NULL || indices == NULL || count <= 0 )
		hl_error("HashLink native module patch slots require two modules and a non-empty slot table");
	return hl_module_patch_slots((hl_module*)target,(hl_module*)generation,indices,count) != 0;
}

HL_PRIM void HL_NAME(native_metadata_module_free_shutdown)( vbyte *module ) {
	if( module != NULL ) {
		haxeon_gc_handle_detach_owner(module);
		hl_module_free_shutdown((hl_module*)module);
	}
}

HL_PRIM int HL_NAME(native_metadata_module_call_i32)( vbyte *module, int findex ) {
	hl_module *m = (hl_module*)module;
	hl_function *function;
	vclosure closure = {0};
	vclosure *cl = &closure;
	hl_trap_ctx trap;
	vdynamic *exception;
	int result;

	if( m == NULL || m->code == NULL )
		hl_error("HashLink native module call requires an initialized module");
	if( findex < 0 || findex >= m->code->nfunctions + m->code->nnatives )
		hl_error("HashLink native module function index is outside the dispatch table");
	function = native_metadata_find_function(m->code->functions,m->code->nfunctions,findex);
	if( function == NULL || function->type == NULL || function->type->kind != HFUN || function->type->fun == NULL
		|| function->type->fun->nargs != 0 || function->type->fun->ret == NULL || function->type->fun->ret->kind != HI32 )
		hl_error("HashLink native module call requires a zero-argument i32 function");
	if( m->functions_ptrs == NULL || m->functions_ptrs[findex] == NULL )
		hl_error("HashLink native module function has no installed entrypoint");
	closure.t = function->type;
	closure.fun = m->functions_ptrs[findex];
	closure.hasValue = 0;
	hl_trap(trap,exception,on_exception);
	result = hl_call0(int,cl);
	hl_endtrap(trap);
	return result;
on_exception:
	hl_endtrap(trap);
	hl_error("HashLink native module function raised an exception");
	return 0;
}

HL_PRIM void HL_NAME(native_module_context_dispose)( hl_module_context *context ) {
	if( context == NULL ) return;
	hl_free(&context->alloc);
	context->functions_ptrs = NULL;
	context->functions_types = NULL;
}
