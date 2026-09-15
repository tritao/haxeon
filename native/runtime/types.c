HL_PRIM int HL_NAME(native_type_kind)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	return (int)type->kind;
}

HL_PRIM int HL_NAME(native_type_size)( hl_type *type ) {
	if( type == NULL ) hl_error("HashLink type metadata pointer must not be null");
	return hl_type_size(type);
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

HL_PRIM void HL_NAME(native_type_initialize_enum)( hl_type *type, hl_module_context *context ) {
	if( type == NULL || type->kind != HENUM || type->tenum == NULL || context == NULL )
		hl_error("HashLink enum metadata initialization requires an enum and module context");
	hl_init_enum(type,context);
}

HL_PRIM void HL_NAME(native_type_initialize_virtual)( hl_type *type, hl_module_context *context ) {
	if( type == NULL || type->kind != HVIRTUAL || type->virt == NULL || context == NULL )
		hl_error("HashLink virtual metadata initialization requires a virtual type and module context");
	hl_init_virtual(type,context);
}

HL_PRIM void HL_NAME(native_metadata_initialize)( hl_type **types, int count, hl_module_context *context ) {
	int i;
	if( count < 0 || (count > 0 && types == NULL) || context == NULL )
		hl_error("HashLink metadata publication requires a type table and module context");
	for( i = 0; i < count; i++ ) {
		hl_type *type = types[i];
		if( type == NULL ) hl_error("HashLink metadata publication contains a null type");
		switch( type->kind ) {
		case HOBJ:
		case HSTRUCT:
			if( type->obj == NULL || type->obj->m == NULL )
				hl_error("HashLink object metadata publication requires a module context");
			hl_get_obj_proto(type);
			break;
		case HENUM:
			if( type->tenum == NULL ) hl_error("HashLink metadata publication contains an invalid enum");
			hl_init_enum(type,context);
			break;
		case HVIRTUAL:
			if( type->virt == NULL ) hl_error("HashLink metadata publication contains an invalid virtual type");
			hl_init_virtual(type,context);
			break;
		default:
			break;
		}
	}
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
