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

HL_PRIM int HL_NAME(native_type_data_size)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	if( type->kind != HOBJ && type->kind != HSTRUCT )
		hl_error("HashLink type metadata pointer must reference an object type");
	return hl_get_obj_rt(type)->size;
}

HL_PRIM int HL_NAME(native_type_object_field_offset)( hl_type *type, int field ) {
	hl_runtime_obj *runtime;
	if( type == NULL || (type->kind != HOBJ && type->kind != HSTRUCT) )
		hl_error("HashLink type metadata pointer must reference an object type");
	runtime = hl_get_obj_rt(type);
	if( field < 0 || field >= runtime->nfields )
		hl_error("HashLink object field index is outside the runtime layout");
	return runtime->fields_indexes[field];
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

static void native_metadata_bind_function_descriptors_for_type( hl_type *type, hl_function *functions, int function_count, hl_module_context *context ) {
	hl_type_obj *object;
	int i;
	if( type->kind != HOBJ && type->kind != HSTRUCT ) return;
	object = type->obj;
	if( object == NULL ) hl_error("HashLink function descriptor binding contains an invalid object");
	if( (object->nproto > 0 && object->proto == NULL) || (object->nbindings > 0 && object->bindings == NULL) )
		hl_error("HashLink function descriptor binding contains incomplete object metadata");
	object->m = context;
	for( i = 0; i < object->nproto; i++ ) {
		hl_obj_proto *prototype = object->proto + i;
		hl_function *function = native_metadata_find_function(functions,function_count,prototype->findex);
		if( function == NULL ) hl_error("HashLink function descriptor binding references an unknown prototype");
		function->obj = object;
		function->field.name = prototype->name;
	}
	for( i = 0; i < object->nbindings; i++ ) {
		int field_id = object->bindings[i << 1];
		int function_id = object->bindings[(i << 1) | 1];
		hl_obj_field *field = hl_obj_field_fetch(type,field_id);
		if( field == NULL ) hl_error("HashLink function descriptor binding references an unknown field");
		if( field->t == NULL ) hl_error("HashLink function descriptor binding references a field without a type");
		if( field->t->kind == HFUN || field->t->kind == HDYN ) {
			hl_function *function = native_metadata_find_function(functions,function_count,function_id);
			if( function == NULL ) hl_error("HashLink function descriptor binding references an unknown method");
			function->obj = object;
			function->field.name = field->name;
		}
	}
}

static void native_metadata_validate_function_descriptors( int count, hl_function *functions ) {
	if( count < 0 || (count > 0 && functions == NULL) )
		hl_error("HashLink function descriptor binding requires a descriptor table");
}

HL_PRIM void HL_NAME(native_metadata_bind_function_descriptors)( hl_type **types, int count, hl_function *functions, int function_count, hl_module_context *context ) {
	int i;
	native_metadata_validate_publication(count,types,context);
	native_metadata_validate_function_descriptors(function_count,functions);
	for( i = 0; i < count; i++ ) {
		if( types[i] == NULL ) hl_error("HashLink metadata contains a null type");
		native_metadata_bind_function_descriptors_for_type(types[i],functions,function_count,context);
	}
}

HL_PRIM void HL_NAME(native_metadata_bind_contiguous_function_descriptors)( hl_type *types, int count, hl_function *functions, int function_count, hl_module_context *context ) {
	int i;
	native_metadata_validate_publication(count,types,context);
	native_metadata_validate_function_descriptors(function_count,functions);
	for( i = 0; i < count; i++ )
		native_metadata_bind_function_descriptors_for_type(types + i,functions,function_count,context);
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
