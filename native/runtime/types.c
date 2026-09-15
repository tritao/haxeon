HL_API int hl_mark_size( int data_size );

HL_PRIM int HL_NAME(native_type_kind)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	return (int)type->kind;
}

HL_PRIM int HL_NAME(native_type_size)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	return hl_type_size(type);
}

HL_PRIM int HL_NAME(native_type_pad_struct)( hl_type *type, int size ) {
	if( type == NULL || size < 0 ) hl_error("HashLink type layout padding requires a type and non-negative size");
	return hl_pad_struct(size,type);
}

HL_PRIM bool HL_NAME(native_type_is_ptr)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	return hl_is_ptr(type);
}

HL_PRIM int HL_NAME(native_type_mark_size)( int size ) {
	if( size < 0 ) hl_error("HashLink mark-bit size must be non-negative");
	return hl_mark_size(size);
}

HL_PRIM int HL_NAME(native_pointer_size)() {
	return (int)sizeof(void*);
}

HL_PRIM void HL_NAME(native_type_initialize_object)( hl_type *type ) {
	if( type == NULL || (type->kind != HOBJ && type->kind != HSTRUCT) || type->obj == NULL || type->obj->m == NULL )
		hl_error("HashLink object metadata initialization requires an object with a module context");
	hl_get_obj_proto(type);
}

static void native_metadata_publish_prototype( hl_type *type ) {
	switch( type->kind ) {
	case HOBJ:
	case HSTRUCT:
		if( type->obj == NULL || type->obj->m == NULL )
			hl_error("HashLink object metadata publication requires a module context");
		hl_get_obj_proto(type);
		break;
	case HENUM:
		if( type->tenum == NULL ) hl_error("HashLink metadata publication contains an invalid enum");
		break;
	case HVIRTUAL:
		if( type->virt == NULL ) hl_error("HashLink metadata publication contains an invalid virtual type");
		break;
	default:
		break;
	}
}

static void native_metadata_validate_publication( int count, void *types, hl_module_context *context ) {
	if( count < 0 || (count > 0 && types == NULL) || context == NULL )
		hl_error("HashLink metadata publication requires a type table and module context");
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
	return hl_module_init((hl_module*)module,flags) != 0;
}

HL_PRIM bool HL_NAME(native_metadata_module_unload)( vbyte *module ) {
	if( module == NULL ) return false;
	return hl_module_unload((hl_module*)module) != 0;
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
	if( module != NULL ) hl_module_free_shutdown((hl_module*)module);
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

HL_PRIM void HL_NAME(native_metadata_publish_prototypes)( hl_type **types, int count, hl_module_context *context ) {
	int i;
	native_metadata_validate_publication(count,types,context);
	for( i = 0; i < count; i++ ) {
		hl_type *type = types[i];
		if( type == NULL ) hl_error("HashLink metadata publication contains a null type");
		native_metadata_publish_prototype(type);
	}
}

HL_PRIM void HL_NAME(native_metadata_publish_contiguous_prototypes)( hl_type *types, int count, hl_module_context *context ) {
	int i;
	native_metadata_validate_publication(count,types,context);
	for( i = 0; i < count; i++ )
		native_metadata_publish_prototype(types + i);
}

HL_PRIM void HL_NAME(native_module_context_dispose)( hl_module_context *context ) {
	if( context == NULL ) return;
	hl_free(&context->alloc);
	context->functions_ptrs = NULL;
	context->functions_types = NULL;
}

HL_PRIM int HL_NAME(native_type_function_arity)( hl_type *type ) {
	if( type == NULL || type->kind != HFUN || type->fun == NULL )
		hl_error("HashLink type metadata pointer must reference a function type");
	return type->fun->nargs;
}

HL_PRIM int HL_NAME(native_type_object_field_count)( hl_type *type ) {
	if( type == NULL || type->kind != HOBJ || type->obj == NULL )
		hl_error("HashLink type metadata pointer must reference an object type");
	return type->obj->nfields;
}

HL_PRIM int HL_NAME(native_type_enum_constructor_count)( hl_type *type ) {
	if( type == NULL || type->kind != HENUM || type->tenum == NULL )
		hl_error("HashLink type metadata pointer must reference an enum type");
	return type->tenum->nconstructs;
}

HL_PRIM int HL_NAME(native_type_virtual_field_count)( hl_type *type ) {
	if( type == NULL || type->kind != HVIRTUAL || type->virt == NULL )
		hl_error("HashLink type metadata pointer must reference a virtual type");
	return type->virt->nfields;
}
