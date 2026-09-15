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

HL_PRIM int HL_NAME(native_metadata_validate_function_code)( hl_function *function ) {
	int i;
	if( function == NULL )
		hl_error("HashLink function code validation requires a function descriptor");
	if( function->nops < 0 || (function->nops > 0 && function->ops == NULL) )
		hl_error("HashLink function descriptor contains an incomplete opcode array");
	for( i = 0; i < function->nops; i++ ) {
		if( function->ops[i].op < 0 || function->ops[i].op >= OLast )
			hl_error("HashLink function descriptor contains an invalid opcode");
	}
	return function->nops;
}

HL_PRIM int HL_NAME(native_metadata_validate_debug_files)( uchar **files, int count ) {
	int i;
	if( count < 0 || (count > 0 && files == NULL) )
		hl_error("HashLink debug metadata requires a debug-file table");
	for( i = 0; i < count; i++ )
		if( files[i] == NULL ) hl_error("HashLink debug metadata contains a null file name");
	return count;
}

HL_PRIM int HL_NAME(native_metadata_validate_function_debug)( hl_function *function, int debug_file_count ) {
	int i;
	if( function == NULL || debug_file_count < 0 )
		hl_error("HashLink function debug validation requires a function descriptor and file count");
	if( function->debug != NULL ) {
		if( debug_file_count == 0 ) hl_error("HashLink function debug metadata has no file table");
		for( i = 0; i < function->nops; i++ ) {
			int file = function->debug[i << 1];
			int line = function->debug[(i << 1) | 1];
			if( file < 0 || file >= debug_file_count || line < 1 )
				hl_error("HashLink function debug metadata contains an invalid location");
		}
	}
	if( function->nassigns < 0 || (function->nassigns > 0 && function->assigns == NULL) )
		hl_error("HashLink function debug metadata contains an incomplete assignment table");
	for( i = 0; i < function->nassigns; i++ ) {
		int position = function->assigns[i * 3 + 1];
		int scope_end = function->assigns[i * 3 + 2];
		if( position < -1 || scope_end < -1 )
			hl_error("HashLink function debug metadata contains an invalid assignment range");
	}
	return function->nassigns;
}

static bool native_metadata_contains_global_slot( void **globals, int count, void **value ) {
	int i;
	for( i = 0; i < count; i++ )
		if( value == globals + i ) return true;
	return false;
}

HL_PRIM int HL_NAME(native_metadata_validate_global_types)( hl_type **types, int count, void **globals ) {
	int i;
	if( count < 0 || (count > 0 && (types == NULL || globals == NULL)) )
		hl_error("HashLink global metadata requires matching type and value tables");
	for( i = 0; i < count; i++ ) {
		hl_type *type = types[i];
		if( type == NULL || type->kind < HVOID || type->kind >= HLAST )
			hl_error("HashLink global metadata contains an invalid type");
		if( type->kind == HOBJ || type->kind == HSTRUCT ) {
			if( type->obj == NULL ) hl_error("HashLink global metadata contains an invalid object type");
			if( type->obj->global_value != NULL && !native_metadata_contains_global_slot(globals,count,type->obj->global_value) )
				hl_error("HashLink object global value is outside the published value table");
		} else if( type->kind == HENUM ) {
			if( type->tenum == NULL ) hl_error("HashLink global metadata contains an invalid enum type");
			if( type->tenum->global_value != NULL && !native_metadata_contains_global_slot(globals,count,type->tenum->global_value) )
				hl_error("HashLink enum global value is outside the published value table");
		}
	}
	return count;
}

HL_PRIM int HL_NAME(native_metadata_validate_constants)( hl_constant *constants, int count, int global_count ) {
	int i, j;
	if( count < 0 || global_count < 0 || (count > 0 && constants == NULL) )
		hl_error("HashLink constant metadata requires a descriptor table and global count");
	for( i = 0; i < count; i++ ) {
		hl_constant *constant = constants + i;
		if( constant->global < 0 || constant->global >= global_count || constant->nfields < 0 || (constant->nfields > 0 && constant->fields == NULL) )
			hl_error("HashLink constant metadata contains invalid storage metadata");
		for( j = 0; j < constant->nfields; j++ )
			if( constant->fields[j] < 0 ) hl_error("HashLink constant metadata contains an invalid field index");
	}
	return count;
}

HL_PRIM int HL_NAME(native_metadata_validate_module_pools)( int *ints, int int_count, double *floats, int float_count, char **strings, int *string_lengths,
	int string_count, uchar *bytes, int byte_count, int *byte_positions, int byte_position_count, int entrypoint ) {
	int i;
	if( int_count < 0 || float_count < 0 || string_count < 0 || byte_count < 0 || byte_position_count < 0 || entrypoint < 0 )
		hl_error("HashLink module pools contain invalid counts");
	if( (int_count > 0 && ints == NULL) || (float_count > 0 && floats == NULL)
		|| (string_count > 0 && (strings == NULL || string_lengths == NULL))
		|| (byte_count > 0 && bytes == NULL) || (byte_position_count > 0 && byte_positions == NULL) )
		hl_error("HashLink module pools contain incomplete storage");
	for( i = 0; i < string_count; i++ )
		if( strings[i] == NULL || string_lengths[i] < 0 )
			hl_error("HashLink module string pool contains invalid storage");
	for( i = 0; i < byte_position_count; i++ )
		if( byte_positions[i] < 0 || byte_positions[i] >= byte_count )
			hl_error("HashLink byte position is outside the byte pool");
	return string_count;
}

HL_PRIM int HL_NAME(native_metadata_validate_debug_sections)( hl_debug_section *sections, int count ) {
	int i;
	if( count < 0 || (count > 0 && sections == NULL) )
		hl_error("HashLink debug sections require a descriptor table");
	for( i = 0; i < count; i++ ) {
		hl_debug_section *section = sections + i;
		if( section->kind <= 0 || section->version <= 0 || section->flags < 0 || section->size < 0
			|| (section->size > 0 && section->data == NULL) )
			hl_error("HashLink debug section contains invalid storage metadata");
	}
	return count;
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
