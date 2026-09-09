#define HAXEON_NATIVE_MAX_ARGUMENTS 16
#define HAXEON_NATIVE_SLOT_SIZE 8

enum haxeon_native_type {
	HAXEON_NATIVE_VOID = 0,
	HAXEON_NATIVE_I8 = 1,
	HAXEON_NATIVE_U8 = 2,
	HAXEON_NATIVE_I16 = 3,
	HAXEON_NATIVE_U16 = 4,
	HAXEON_NATIVE_I32 = 5,
	HAXEON_NATIVE_U32 = 6,
	HAXEON_NATIVE_I64 = 7,
	HAXEON_NATIVE_U64 = 8,
	HAXEON_NATIVE_F32 = 9,
	HAXEON_NATIVE_F64 = 10,
	HAXEON_NATIVE_POINTER = 11
};

typedef struct haxeon_native_control {
	void *handle;
	int references;
} haxeon_native_control;

typedef struct haxeon_native_library {
	void (*finalize)( void * );
	haxeon_native_control *control;
} haxeon_native_library;

typedef struct haxeon_native_function {
	void (*finalize)( void * );
	haxeon_native_control *control;
	void *symbol;
	ffi_cif cif;
	ffi_type *argument_types[HAXEON_NATIVE_MAX_ARGUMENTS];
	int argument_count;
	int result_type;
} haxeon_native_function;

typedef struct haxeon_native_pointer {
	void (*finalize)( void * );
	haxeon_native_control *control;
	void *value;
	void (*release)( void * );
} haxeon_native_pointer;

typedef struct haxeon_native_callback {
	void (*finalize)( void * );
	ffi_cif cif;
	ffi_closure *closure_memory;
	void *code;
	vclosure *closure;
	hl_thread *thread;
	ffi_type *argument_types[HAXEON_NATIVE_MAX_ARGUMENTS];
	unsigned char argument_codes[HAXEON_NATIVE_MAX_ARGUMENTS];
	int pointer_sizes[HAXEON_NATIVE_MAX_ARGUMENTS];
	bool pointer_nullable[HAXEON_NATIVE_MAX_ARGUMENTS];
	int argument_count;
	int result_code;
} haxeon_native_callback;

#ifdef _WIN32
#define HAXEON_NATIVE_TLS __declspec(thread)
#else
#define HAXEON_NATIVE_TLS _Thread_local
#endif

static HAXEON_NATIVE_TLS char haxeon_native_error[512];

static void haxeon_native_set_error( const char *message ) {
	if( message == NULL ) message = "Unknown native loader error";
	snprintf(haxeon_native_error,sizeof(haxeon_native_error),"%s",message);
}

static char *haxeon_native_string( const vbyte *bytes, int length ) {
	if( bytes == NULL || length < 0 ) return NULL;
	if( memchr(bytes,0,(size_t)length) != NULL ) return NULL;
	char *result = (char *)malloc((size_t)length + 1);
	if( result == NULL ) return NULL;
	if( length > 0 ) memcpy(result,bytes,(size_t)length);
	result[length] = 0;
	return result;
}

static void haxeon_native_unload( void *handle ) {
	if( handle == NULL ) return;
#ifdef _WIN32
	FreeLibrary((HMODULE)handle);
#else
	dlclose(handle);
#endif
}

static void haxeon_native_release_control( haxeon_native_control *control ) {
	if( control == NULL ) return;
	control->references--;
	if( control->references == 0 ) {
		haxeon_native_unload(control->handle);
		control->handle = NULL;
		free(control);
	}
}

static void haxeon_native_library_finalize( void *value ) {
	haxeon_native_library *library = (haxeon_native_library *)value;
	haxeon_native_release_control(library->control);
	library->control = NULL;
}

static void haxeon_native_function_finalize( void *value ) {
	haxeon_native_function *function = (haxeon_native_function *)value;
	haxeon_native_release_control(function->control);
	function->control = NULL;
	function->symbol = NULL;
}

static void haxeon_native_pointer_finalize( void *value ) {
	haxeon_native_pointer *pointer = (haxeon_native_pointer *)value;
	if( pointer->value != NULL && pointer->release != NULL ) pointer->release(pointer->value);
	pointer->value = NULL;
	pointer->release = NULL;
	haxeon_native_release_control(pointer->control);
	pointer->control = NULL;
}

HL_PRIM haxeon_native_pointer *HL_NAME(structGetPointer)( realtime_bytes *bytes, int offset, bool nullable ) {
	realtime_bytes_bounds(bytes,offset,sizeof(void *));
	void *value;
	memcpy(&value,bytes->data + offset,sizeof(value));
	if( value == NULL ) {
		if( nullable ) return NULL;
		hl_error("Non-null HXI structure pointer field contains NULL");
	}
	haxeon_native_pointer *pointer = (haxeon_native_pointer *)hl_gc_alloc_finalizer(sizeof(haxeon_native_pointer));
	memset(pointer,0,sizeof(*pointer));
	pointer->finalize = haxeon_native_pointer_finalize;
	pointer->value = value;
	return pointer;
}

HL_PRIM void HL_NAME(structSetPointer)( realtime_bytes *bytes, int offset, haxeon_native_pointer *pointer, bool nullable ) {
	realtime_bytes_bounds(bytes,offset,sizeof(void *));
	void *value = NULL;
	if( pointer == NULL ) {
		if( !nullable ) hl_error("Cannot assign NULL to a non-null HXI structure pointer field");
	} else {
		if( pointer->value == NULL ) hl_error("Cannot assign a closed native pointer to an HXI structure field");
		value = pointer->value;
	}
	memcpy(bytes->data + offset,&value,sizeof(value));
}

static ffi_type *haxeon_native_ffi_type( int type, bool result ) {
	switch( type ) {
	case HAXEON_NATIVE_VOID: return result ? &ffi_type_void : NULL;
	case HAXEON_NATIVE_I8: return &ffi_type_sint8;
	case HAXEON_NATIVE_U8: return &ffi_type_uint8;
	case HAXEON_NATIVE_I16: return &ffi_type_sint16;
	case HAXEON_NATIVE_U16: return &ffi_type_uint16;
	case HAXEON_NATIVE_I32: return &ffi_type_sint32;
	case HAXEON_NATIVE_U32: return &ffi_type_uint32;
	case HAXEON_NATIVE_I64: return &ffi_type_sint64;
	case HAXEON_NATIVE_U64: return &ffi_type_uint64;
	case HAXEON_NATIVE_F32: return &ffi_type_float;
	case HAXEON_NATIVE_F64: return &ffi_type_double;
	case HAXEON_NATIVE_POINTER: return &ffi_type_pointer;
	default: return NULL;
	}
}

static void haxeon_native_callback_release( haxeon_native_callback *callback ) {
	if( callback->closure != NULL ) {
		hl_remove_root(&callback->closure);
		callback->closure = NULL;
	}
	if( callback->closure_memory != NULL ) {
		ffi_closure_free(callback->closure_memory);
		callback->closure_memory = NULL;
		callback->code = NULL;
	}
}

static void haxeon_native_callback_finalize( void *value ) {
	haxeon_native_callback_release((haxeon_native_callback *)value);
}

static void haxeon_native_scoped_bytes_finalize( void *value ) {
	realtime_bytes *bytes = (realtime_bytes *)value;
	bytes->data = NULL;
	bytes->length = 0;
}

static vdynamic *haxeon_native_callback_argument( haxeon_native_callback *callback, int index, void *value, bool *valid ) {
	vdynamic *result;
	int code = callback->argument_codes[index];
	switch( code ) {
	case HAXEON_NATIVE_I8: result = hl_alloc_dynamic(&hlt_i32); result->v.i = *(int8_t *)value; return result;
	case HAXEON_NATIVE_U8: result = hl_alloc_dynamic(&hlt_i32); result->v.i = *(uint8_t *)value; return result;
	case HAXEON_NATIVE_I16: result = hl_alloc_dynamic(&hlt_i32); result->v.i = *(int16_t *)value; return result;
	case HAXEON_NATIVE_U16: result = hl_alloc_dynamic(&hlt_i32); result->v.i = *(uint16_t *)value; return result;
	case HAXEON_NATIVE_I32: case HAXEON_NATIVE_U32: result = hl_alloc_dynamic(&hlt_i32); result->v.i = *(int32_t *)value; return result;
	case HAXEON_NATIVE_I64: case HAXEON_NATIVE_U64: result = hl_alloc_dynamic(&hlt_i64); result->v.i64 = *(int64_t *)value; return result;
	case HAXEON_NATIVE_F32: result = hl_alloc_dynamic(&hlt_f64); result->v.d = *(float *)value; return result;
	case HAXEON_NATIVE_F64: result = hl_alloc_dynamic(&hlt_f64); result->v.d = *(double *)value; return result;
	case HAXEON_NATIVE_POINTER: {
		void *pointer = *(void **)value;
		if( pointer == NULL ) {
			if( !callback->pointer_nullable[index] ) *valid = false;
			return NULL;
		}
		hl_type *expected = callback->closure->t->fun->args[index];
		if( expected->kind != HABSTRACT ) { *valid = false; return NULL; }
		const char *name = hl_to_utf8(expected->abs_name);
		result = hl_alloc_dynamic(expected);
		if( strcmp(name,"native_pointer") == 0 ) {
			haxeon_native_pointer *wrapped = (haxeon_native_pointer *)hl_gc_alloc_finalizer(sizeof(haxeon_native_pointer));
			memset(wrapped,0,sizeof(*wrapped));
			wrapped->finalize = haxeon_native_pointer_finalize;
			wrapped->value = pointer;
			result->v.ptr = wrapped;
			return result;
		}
		if( strcmp(name,"realtime_bytes") == 0 && callback->pointer_sizes[index] > 0 ) {
			realtime_bytes *wrapped = (realtime_bytes *)hl_gc_alloc_finalizer(sizeof(realtime_bytes));
			wrapped->finalize = haxeon_native_scoped_bytes_finalize;
			wrapped->data = (vbyte *)pointer;
			wrapped->length = callback->pointer_sizes[index];
			result->v.ptr = wrapped;
			return result;
		}
		*valid = false;
		return NULL;
	}
	default: return NULL;
	}
}

static void haxeon_native_callback_invalidate( vdynamic *argument ) {
	if( argument == NULL || argument->t == NULL || argument->t->kind != HABSTRACT ) return;
	const char *name = hl_to_utf8(argument->t->abs_name);
	if( strcmp(name,"native_pointer") == 0 )
		((haxeon_native_pointer *)argument->v.ptr)->value = NULL;
	else if( strcmp(name,"realtime_bytes") == 0 ) {
		((realtime_bytes *)argument->v.ptr)->data = NULL;
		((realtime_bytes *)argument->v.ptr)->length = 0;
	}
}

static void haxeon_native_callback_zero( int code, void *output ) {
	if( output == NULL || code == HAXEON_NATIVE_VOID ) return;
	switch( code ) {
	case HAXEON_NATIVE_I8: case HAXEON_NATIVE_U8: *(uint8_t *)output = 0; break;
	case HAXEON_NATIVE_I16: case HAXEON_NATIVE_U16: *(uint16_t *)output = 0; break;
	case HAXEON_NATIVE_I32: case HAXEON_NATIVE_U32: case HAXEON_NATIVE_F32: *(uint32_t *)output = 0; break;
	case HAXEON_NATIVE_I64: case HAXEON_NATIVE_U64: case HAXEON_NATIVE_F64: *(uint64_t *)output = 0; break;
	default: break;
	}
}

static void haxeon_native_callback_dispatch( ffi_cif *cif, void *output, void **values, void *user_data ) {
	(void)cif;
	haxeon_native_callback *callback = (haxeon_native_callback *)user_data;
	if( callback->closure == NULL || callback->thread != hl_thread_current() ) {
		haxeon_native_callback_zero(callback->result_code,output);
		return;
	}
	vdynamic *arguments[HAXEON_NATIVE_MAX_ARGUMENTS];
	bool valid = true;
	for( int index = 0; index < callback->argument_count; index++ )
		arguments[index] = haxeon_native_callback_argument(callback,index,values[index],&valid);
	if( !valid ) {
		for( int index = 0; index < callback->argument_count; index++ ) haxeon_native_callback_invalidate(arguments[index]);
		haxeon_native_callback_zero(callback->result_code,output);
		return;
	}
	bool raised = false;
	vdynamic *result = hl_dyn_call_safe(callback->closure,arguments,callback->argument_count,&raised);
	for( int index = 0; index < callback->argument_count; index++ ) haxeon_native_callback_invalidate(arguments[index]);
	if( callback->result_code == HAXEON_NATIVE_VOID ) return;
	if( raised || result == NULL ) { haxeon_native_callback_zero(callback->result_code,output); return; }
	switch( callback->result_code ) {
	case HAXEON_NATIVE_I8: *(int8_t *)output = (int8_t)result->v.i; break;
	case HAXEON_NATIVE_U8: *(uint8_t *)output = (uint8_t)result->v.i; break;
	case HAXEON_NATIVE_I16: *(int16_t *)output = (int16_t)result->v.i; break;
	case HAXEON_NATIVE_U16: *(uint16_t *)output = (uint16_t)result->v.i; break;
	case HAXEON_NATIVE_I32: case HAXEON_NATIVE_U32: *(int32_t *)output = result->v.i; break;
	case HAXEON_NATIVE_I64: case HAXEON_NATIVE_U64: *(int64_t *)output = result->v.i64; break;
	case HAXEON_NATIVE_F32: *(float *)output = (float)result->v.d; break;
	case HAXEON_NATIVE_F64: *(double *)output = result->v.d; break;
	default: haxeon_native_callback_zero(callback->result_code,output); break;
	}
}

HL_PRIM haxeon_native_library *HL_NAME(native_open)( vbyte *path_bytes, int path_length ) {
	char *path = haxeon_native_string(path_bytes,path_length);
	if( path == NULL ) {
		haxeon_native_set_error("Invalid or out-of-memory library path");
		return NULL;
	}
	void *handle = NULL;
#ifdef _WIN32
	int wide_length = MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
	if( wide_length > 0 ) {
		wchar_t *wide = (wchar_t *)malloc((size_t)wide_length * sizeof(wchar_t));
		if( wide != NULL ) {
			MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,wide_length);
			handle = (void *)LoadLibraryW(wide);
			free(wide);
		}
	}
	if( handle == NULL ) haxeon_native_set_error("LoadLibraryW failed");
#else
	dlerror();
	handle = dlopen(path,RTLD_NOW | RTLD_LOCAL);
	if( handle == NULL ) haxeon_native_set_error(dlerror());
#endif
	free(path);
	if( handle == NULL ) return NULL;
	haxeon_native_control *control = (haxeon_native_control *)malloc(sizeof(haxeon_native_control));
	if( control == NULL ) {
		haxeon_native_unload(handle);
		haxeon_native_set_error("Could not allocate native library control");
		return NULL;
	}
	control->handle = handle;
	control->references = 1;
	haxeon_native_library *library = (haxeon_native_library *)hl_gc_alloc_finalizer(sizeof(haxeon_native_library));
	library->finalize = haxeon_native_library_finalize;
	library->control = control;
	haxeon_native_error[0] = 0;
	return library;
}

HL_PRIM bool HL_NAME(native_close)( haxeon_native_library *library ) {
	if( library == NULL || library->control == NULL ) return false;
	haxeon_native_release_control(library->control);
	library->control = NULL;
	return true;
}

HL_PRIM haxeon_native_function *HL_NAME(native_resolve)( haxeon_native_library *library, vbyte *symbol_bytes, int symbol_length,
	vbyte *argument_codes, int argument_count, int result_type ) {
	if( library == NULL || library->control == NULL || library->control->handle == NULL ) {
		haxeon_native_set_error("Native library is closed");
		return NULL;
	}
	if( argument_count < 0 || argument_count > HAXEON_NATIVE_MAX_ARGUMENTS || (argument_count > 0 && argument_codes == NULL) ) {
		haxeon_native_set_error("Invalid native call argument signature");
		return NULL;
	}
	char *symbol_name = haxeon_native_string(symbol_bytes,symbol_length);
	if( symbol_name == NULL ) {
		haxeon_native_set_error("Invalid or out-of-memory symbol name");
		return NULL;
	}
	void *symbol = NULL;
#ifdef _WIN32
	symbol = (void *)GetProcAddress((HMODULE)library->control->handle,symbol_name);
	if( symbol == NULL ) haxeon_native_set_error("GetProcAddress failed");
#else
	dlerror();
	symbol = dlsym(library->control->handle,symbol_name);
	const char *loader_error = dlerror();
	if( loader_error != NULL ) {
		haxeon_native_set_error(loader_error);
		symbol = NULL;
	}
#endif
	free(symbol_name);
	if( symbol == NULL ) return NULL;
	haxeon_native_function *function = (haxeon_native_function *)hl_gc_alloc_finalizer(sizeof(haxeon_native_function));
	memset(function,0,sizeof(*function));
	function->finalize = haxeon_native_function_finalize;
	function->symbol = symbol;
	function->argument_count = argument_count;
	function->result_type = result_type;
	for( int index = 0; index < argument_count; index++ ) {
		function->argument_types[index] = haxeon_native_ffi_type(argument_codes[index],false);
		if( function->argument_types[index] == NULL ) {
			haxeon_native_set_error("Unsupported native call argument type");
			function->symbol = NULL;
			return NULL;
		}
	}
	ffi_type *ffi_result = haxeon_native_ffi_type(result_type,true);
	if( ffi_result == NULL || ffi_prep_cif(&function->cif,FFI_DEFAULT_ABI,(unsigned int)argument_count,ffi_result,function->argument_types) != FFI_OK ) {
		haxeon_native_set_error("Could not prepare native call signature");
		function->symbol = NULL;
		return NULL;
	}
	function->control = library->control;
	function->control->references++;
	haxeon_native_error[0] = 0;
	return function;
}

HL_PRIM int HL_NAME(native_call)( haxeon_native_function *function, vbyte *arguments, int argument_length, vbyte *output, int output_length ) {
	if( function == NULL || function->symbol == NULL || function->control == NULL ) {
		haxeon_native_set_error("Invalid native call function");
		return -1;
	}
	if( argument_length != function->argument_count * HAXEON_NATIVE_SLOT_SIZE || (argument_length > 0 && arguments == NULL) ) {
		haxeon_native_set_error("Native argument buffer has the wrong size");
		return -2;
	}
	if( function->result_type != HAXEON_NATIVE_VOID && (output == NULL || output_length < HAXEON_NATIVE_SLOT_SIZE) ) {
		haxeon_native_set_error("Native result buffer is too small");
		return -3;
	}
	void *values[HAXEON_NATIVE_MAX_ARGUMENTS];
	for( int index = 0; index < function->argument_count; index++ )
		values[index] = arguments + index * HAXEON_NATIVE_SLOT_SIZE;
	union { uint64_t integer; double floating; void *pointer; } result;
	memset(&result,0,sizeof(result));
	ffi_call(&function->cif,FFI_FN(function->symbol),function->result_type == HAXEON_NATIVE_VOID ? NULL : &result,values);
	if( function->result_type != HAXEON_NATIVE_VOID ) memcpy(output,&result,HAXEON_NATIVE_SLOT_SIZE);
	haxeon_native_error[0] = 0;
	return 0;
}

typedef struct haxeon_native_cached_call {
	struct haxeon_native_cached_call *next;
	char *library;
	char *symbol;
	char *signature;
	haxeon_native_function *function;
	unsigned char argument_codes[HAXEON_NATIVE_MAX_ARGUMENTS];
	int argument_count;
	int result_code;
} haxeon_native_cached_call;

static haxeon_native_cached_call *haxeon_native_call_cache;

static bool haxeon_native_parse_signature( const char *signature, unsigned char *arguments, int *argument_count, int *result ) {
	const char *cursor = signature;
	int count = 0;
	while( *cursor != '>' ) {
		char *end;
		long code;
		if( *cursor == 0 || count == HAXEON_NATIVE_MAX_ARGUMENTS ) return false;
		code = strtol(cursor,&end,10);
		if( end == cursor || code < HAXEON_NATIVE_I8 || code > HAXEON_NATIVE_POINTER ) return false;
		arguments[count++] = (unsigned char)code;
		cursor = end;
		if( *cursor == ',' ) cursor++;
		else if( *cursor != '>' ) return false;
	}
	cursor++;
	char *end;
	long result_code = strtol(cursor,&end,10);
	if( end == cursor || *end != 0 || result_code < HAXEON_NATIVE_VOID || result_code > HAXEON_NATIVE_POINTER ) return false;
	*argument_count = count;
	*result = (int)result_code;
	return true;
}

static bool haxeon_native_parse_callback_metadata( realtime_bytes *bytes, int count, int *values ) {
	if( bytes == NULL ) return count == 0;
	char *text = haxeon_native_string(bytes->data,bytes->length), *cursor = text;
	if( text == NULL ) return false;
	for( int index = 0; index < count; index++ ) {
		char *end;
		long value = strtol(cursor,&end,10);
		if( end == cursor || value < 0 || value > 0x7FFFFFFF || (index + 1 < count && *end != ',') || (index + 1 == count && *end != 0) ) {
			free(text);
			return false;
		}
		values[index] = (int)value;
		cursor = *end == ',' ? end + 1 : end;
	}
	free(text);
	return count > 0 || bytes->length == 0;
}

HL_PRIM haxeon_native_callback *HL_NAME(native_callback_create)( realtime_bytes *signature_bytes, realtime_bytes *pointer_sizes,
	realtime_bytes *pointer_nullable, vdynamic *value ) {
	char *signature = signature_bytes == NULL ? NULL : haxeon_native_string(signature_bytes->data,signature_bytes->length);
	if( signature == NULL || value == NULL || value->t == NULL || value->t->kind != HFUN ) {
		free(signature);
		hl_error("Native callback requires a valid signature and function");
	}
	haxeon_native_callback *callback = (haxeon_native_callback *)hl_gc_alloc_finalizer(sizeof(haxeon_native_callback));
	memset(callback,0,sizeof(*callback));
	callback->finalize = haxeon_native_callback_finalize;
	if( !haxeon_native_parse_signature(signature,callback->argument_codes,&callback->argument_count,&callback->result_code) ) {
		free(signature);
		hl_error("Invalid native callback signature");
	}
	free(signature);
	int nullable_values[HAXEON_NATIVE_MAX_ARGUMENTS];
	if( !haxeon_native_parse_callback_metadata(pointer_sizes,callback->argument_count,callback->pointer_sizes)
		|| !haxeon_native_parse_callback_metadata(pointer_nullable,callback->argument_count,nullable_values) )
		hl_error("Invalid native callback pointer metadata");
	for( int index = 0; index < callback->argument_count; index++ ) callback->pointer_nullable[index] = nullable_values[index] != 0;
	for( int index = 0; index < callback->argument_count; index++ ) {
		callback->argument_types[index] = haxeon_native_ffi_type(callback->argument_codes[index],false);
	}
	if( callback->result_code == HAXEON_NATIVE_POINTER ) hl_error("Pointer callback results are not supported yet");
	ffi_type *result = haxeon_native_ffi_type(callback->result_code,true);
	if( result == NULL || ffi_prep_cif(&callback->cif,FFI_DEFAULT_ABI,(unsigned int)callback->argument_count,result,callback->argument_types) != FFI_OK )
		hl_error("Could not prepare native callback signature");
	callback->closure_memory = ffi_closure_alloc(sizeof(ffi_closure),&callback->code);
	if( callback->closure_memory == NULL || callback->code == NULL ) hl_error("Could not allocate executable native callback memory");
	callback->closure = (vclosure *)value;
	callback->thread = hl_thread_current();
	hl_add_root(&callback->closure);
	if( ffi_prep_closure_loc(callback->closure_memory,&callback->cif,haxeon_native_callback_dispatch,callback,callback->code) != FFI_OK ) {
		haxeon_native_callback_release(callback);
		hl_error("Could not prepare executable native callback");
	}
	return callback;
}

HL_PRIM bool HL_NAME(native_callback_close)( haxeon_native_callback *callback ) {
	if( callback == NULL || callback->closure_memory == NULL ) return false;
	haxeon_native_callback_release(callback);
	return true;
}

static haxeon_native_cached_call *haxeon_native_cached_resolve( const char *library_name, const char *symbol, const char *signature ) {
	for( haxeon_native_cached_call *entry = haxeon_native_call_cache; entry != NULL; entry = entry->next )
		if( strcmp(entry->library,library_name) == 0 && strcmp(entry->symbol,symbol) == 0 && strcmp(entry->signature,signature) == 0 ) return entry;
	haxeon_native_cached_call *entry = (haxeon_native_cached_call *)calloc(1,sizeof(haxeon_native_cached_call));
	if( entry == NULL ) hl_error("Could not allocate ordinary C call cache entry");
	if( !haxeon_native_parse_signature(signature,entry->argument_codes,&entry->argument_count,&entry->result_code) )
		hl_error("Invalid ordinary C call signature");
	haxeon_native_library *library = HL_NAME(native_open)((vbyte *)library_name,(int)strlen(library_name));
	if( library == NULL ) hl_error("Could not open ordinary C library: %s",haxeon_native_error);
	entry->function = HL_NAME(native_resolve)(library,(vbyte *)symbol,(int)strlen(symbol),entry->argument_codes,entry->argument_count,entry->result_code);
	HL_NAME(native_close)(library);
	if( entry->function == NULL ) hl_error("Could not resolve ordinary C symbol: %s",haxeon_native_error);
	entry->library = haxeon_native_string((const vbyte *)library_name,(int)strlen(library_name));
	entry->symbol = haxeon_native_string((const vbyte *)symbol,(int)strlen(symbol));
	entry->signature = haxeon_native_string((const vbyte *)signature,(int)strlen(signature));
	if( entry->library == NULL || entry->symbol == NULL || entry->signature == NULL ) hl_error("Could not retain ordinary C call descriptor");
	hl_add_root(&entry->function);
	entry->next = haxeon_native_call_cache;
	haxeon_native_call_cache = entry;
	return entry;
}

static vdynamic *haxeon_native_invoke( vbyte *library, vbyte *symbol, vbyte *signature, vdynamic **arguments, int argument_count ) {
	if( library == NULL || symbol == NULL || signature == NULL ) hl_error("Null ordinary C call descriptor");
	const char *converted = hl_to_utf8((const uchar *)library);
	char *library_name = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	converted = hl_to_utf8((const uchar *)symbol);
	char *symbol_name = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	converted = hl_to_utf8((const uchar *)signature);
	char *signature_text = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	if( library_name == NULL || symbol_name == NULL || signature_text == NULL ) hl_error("Could not convert ordinary C call descriptor");
	haxeon_native_cached_call *entry = haxeon_native_cached_resolve(library_name,symbol_name,signature_text);
	free(library_name);
	free(symbol_name);
	free(signature_text);
	if( entry->argument_count != argument_count ) hl_error("Ordinary C argument count does not match its signature");
	unsigned char slots[HAXEON_NATIVE_MAX_ARGUMENTS * HAXEON_NATIVE_SLOT_SIZE];
	memset(slots,0,sizeof(slots));
	for( int index = 0; index < argument_count; index++ ) {
		vdynamic *value = arguments[index];
		if( value == NULL || value->t == NULL ) {
			if( entry->argument_codes[index] == HAXEON_NATIVE_POINTER ) continue;
			hl_error("Null ordinary C scalar argument");
		}
		switch( entry->argument_codes[index] ) {
		case HAXEON_NATIVE_I8: case HAXEON_NATIVE_U8: case HAXEON_NATIVE_I16: case HAXEON_NATIVE_U16:
		case HAXEON_NATIVE_I32: case HAXEON_NATIVE_U32: memcpy(slots + index * HAXEON_NATIVE_SLOT_SIZE,&value->v.i,sizeof(int)); break;
		case HAXEON_NATIVE_I64: case HAXEON_NATIVE_U64: memcpy(slots + index * HAXEON_NATIVE_SLOT_SIZE,&value->v.i64,sizeof(int64_t)); break;
		case HAXEON_NATIVE_F32: { float converted = (float)value->v.d; memcpy(slots + index * HAXEON_NATIVE_SLOT_SIZE,&converted,sizeof(float)); break; }
		case HAXEON_NATIVE_F64: memcpy(slots + index * HAXEON_NATIVE_SLOT_SIZE,&value->v.d,sizeof(double)); break;
		case HAXEON_NATIVE_POINTER: {
			void *pointer;
			if( value->t->kind != HABSTRACT )
				pointer = value->v.bytes;
			else {
				const char *abstract_name = hl_to_utf8(value->t->abs_name);
				if( strcmp(abstract_name,"native_pointer") == 0 ) {
					haxeon_native_pointer *native_pointer = (haxeon_native_pointer *)value->v.ptr;
					if( native_pointer == NULL || native_pointer->value == NULL ) hl_error("Closed native pointer argument");
					pointer = native_pointer->value;
				} else if( strcmp(abstract_name,"native_callback") == 0 ) {
					haxeon_native_callback *callback = (haxeon_native_callback *)value->v.ptr;
					if( callback == NULL || callback->code == NULL ) hl_error("Closed native callback argument");
					pointer = callback->code;
				} else if( strcmp(abstract_name,"realtime_bytes") == 0 )
					pointer = ((realtime_bytes *)value->v.ptr)->data;
				else
					hl_error("Unsupported abstract ordinary C pointer argument");
			}
			memcpy(slots + index * HAXEON_NATIVE_SLOT_SIZE,&pointer,sizeof(void *));
			break;
		}
		default: hl_error("Unsupported ordinary C argument type");
		}
	}
	unsigned char output[HAXEON_NATIVE_SLOT_SIZE] = {0};
	if( HL_NAME(native_call)(entry->function,slots,argument_count * HAXEON_NATIVE_SLOT_SIZE,output,sizeof(output)) != 0 )
		hl_error("Ordinary C call failed: %s",haxeon_native_error);
	if( entry->result_code == HAXEON_NATIVE_VOID ) return NULL;
	vdynamic *result;
	switch( entry->result_code ) {
	case HAXEON_NATIVE_I8: case HAXEON_NATIVE_U8: case HAXEON_NATIVE_I16: case HAXEON_NATIVE_U16:
	case HAXEON_NATIVE_I32: case HAXEON_NATIVE_U32:
		result = hl_alloc_dynamic(&hlt_i32);
		switch( entry->result_code ) {
		case HAXEON_NATIVE_I8: { int8_t value; memcpy(&value,output,sizeof(value)); result->v.i = value; break; }
		case HAXEON_NATIVE_U8: { uint8_t value; memcpy(&value,output,sizeof(value)); result->v.i = value; break; }
		case HAXEON_NATIVE_I16: { int16_t value; memcpy(&value,output,sizeof(value)); result->v.i = value; break; }
		case HAXEON_NATIVE_U16: { uint16_t value; memcpy(&value,output,sizeof(value)); result->v.i = value; break; }
		default: memcpy(&result->v.i,output,sizeof(int)); break;
		}
		return result;
	case HAXEON_NATIVE_F32: { float value; memcpy(&value,output,sizeof(float)); result = hl_alloc_dynamic(&hlt_f64); result->v.d = value; return result; }
	case HAXEON_NATIVE_F64:
		result = hl_alloc_dynamic(&hlt_f64); memcpy(&result->v.d,output,sizeof(double)); return result;
	case HAXEON_NATIVE_I64: case HAXEON_NATIVE_U64:
		result = hl_alloc_dynamic(&hlt_i64); memcpy(&result->v.i64,output,sizeof(int64_t)); return result;
	case HAXEON_NATIVE_POINTER:
		result = hl_alloc_dynamic(&hlt_bytes); memcpy(&result->v.bytes,output,sizeof(void *)); return result;
	default: hl_error("Unsupported ordinary C result type"); return NULL;
	}
}

static haxeon_native_pointer *haxeon_native_pointer_invoke( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership,
	vbyte *release, bool nullable, vdynamic **arguments, int argument_count ) {
	vdynamic *result = haxeon_native_invoke(library,symbol,signature,arguments,argument_count);
	if( result == NULL || result->t != &hlt_bytes ) hl_error("Ordinary C pointer call returned an invalid value");
	if( result->v.bytes == NULL ) {
		if( nullable ) return NULL;
		hl_error("Non-null ordinary C pointer result returned NULL");
	}
	const char *converted = hl_to_utf8((const uchar *)library);
	char *library_name = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	converted = hl_to_utf8((const uchar *)symbol);
	char *symbol_name = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	converted = hl_to_utf8((const uchar *)signature);
	char *signature_text = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	if( library_name == NULL || symbol_name == NULL || signature_text == NULL ) hl_error("Could not retain ordinary C pointer descriptor");
	haxeon_native_cached_call *entry = haxeon_native_cached_resolve(library_name,symbol_name,signature_text);
	free(library_name);
	free(symbol_name);
	free(signature_text);
	converted = hl_to_utf8((const uchar *)ownership);
	char *ownership_text = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	converted = hl_to_utf8((const uchar *)release);
	char *release_name = haxeon_native_string((const vbyte *)converted,(int)strlen(converted));
	if( ownership_text == NULL || release_name == NULL ) hl_error("Could not retain ordinary C pointer policy");
	haxeon_native_pointer *pointer = (haxeon_native_pointer *)hl_gc_alloc_finalizer(sizeof(haxeon_native_pointer));
	memset(pointer,0,sizeof(*pointer));
	pointer->finalize = haxeon_native_pointer_finalize;
	pointer->value = result->v.bytes;
	if( strcmp(ownership_text,"owned") == 0 ) {
		if( release_name[0] == 0 ) hl_error("Owned ordinary C pointer has no release symbol");
#ifdef _WIN32
		pointer->release = (void (*)(void *))GetProcAddress((HMODULE)entry->function->control->handle,release_name);
#else
		dlerror();
		pointer->release = (void (*)(void *))dlsym(entry->function->control->handle,release_name);
#endif
		if( pointer->release == NULL ) hl_error("Could not resolve ordinary C pointer release symbol");
		pointer->control = entry->function->control;
		pointer->control->references++;
	} else if( strcmp(ownership_text,"borrowed") != 0 )
		hl_error("Ordinary C pointer result has no ownership policy");
	free(ownership_text);
	free(release_name);
	return pointer;
}

HL_PRIM bool HL_NAME(native_pointer_close)( haxeon_native_pointer *pointer ) {
	if( pointer == NULL || pointer->value == NULL || pointer->release == NULL ) return false;
	pointer->release(pointer->value);
	pointer->value = NULL;
	pointer->release = NULL;
	haxeon_native_release_control(pointer->control);
	pointer->control = NULL;
	return true;
}

HL_PRIM bool HL_NAME(native_pointer_is_closed)( haxeon_native_pointer *pointer ) {
	return pointer == NULL || pointer->value == NULL;
}

static realtime_bytes *haxeon_native_bytes_invoke( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership,
	vbyte *release, vbyte *length_symbol, bool nullable, vdynamic **arguments, int argument_count ) {
	const char *signature_utf8 = hl_to_utf8((const uchar *)signature);
	const char *separator = strchr(signature_utf8,'>');
	if( separator == NULL ) hl_error("Invalid ordinary C byte pointer signature");
	size_t prefix = (size_t)(separator - signature_utf8) + 1;
	char length_signature[HAXEON_NATIVE_MAX_ARGUMENTS * 3 + 4];
	if( prefix + 2 > sizeof(length_signature) ) hl_error("Ordinary C byte length signature is too large");
	memcpy(length_signature,signature_utf8,prefix);
	length_signature[prefix] = sizeof(size_t) == 8 ? '8' : '6';
	length_signature[prefix + 1] = 0;
	vbyte *length_signature_value = realtime_string_from_utf8(length_signature);
	vdynamic *length_result = haxeon_native_invoke(library,length_symbol,length_signature_value,arguments,argument_count);
	uint64_t length;
	if( sizeof(size_t) == 8 ) {
		if( length_result == NULL || length_result->t != &hlt_i64 ) hl_error("Ordinary C byte length function returned an invalid value");
		length = (uint64_t)length_result->v.i64;
	} else {
		if( length_result == NULL || length_result->t != &hlt_i32 ) hl_error("Ordinary C byte length function returned an invalid value");
		length = (uint32_t)length_result->v.i;
	}
	if( length > UINT64_C(268435456) ) {
		hl_error("Ordinary C byte result exceeds the 256 MiB safety limit");
	}
	realtime_bytes *bytes = realtime_bytes_make((int)length);
	haxeon_native_pointer *pointer = haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,argument_count);
	if( pointer == NULL ) return NULL;
	if( length > 0 ) memcpy(bytes->data,pointer->value,(size_t)length);
	HL_NAME(native_pointer_close)(pointer);
	return bytes;
}

HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_0)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable ) { return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,NULL,0); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_1)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0 ) { vdynamic *arguments[] = {a0}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,1); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_2)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1 ) { vdynamic *arguments[] = {a0,a1}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,2); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_3)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2 ) { vdynamic *arguments[] = {a0,a1,a2}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,3); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_4)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3 ) { vdynamic *arguments[] = {a0,a1,a2,a3}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,4); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_5)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,5); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_6)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,6); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_7)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,7); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_8)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,8); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_9)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,9); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_10)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,10); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_11)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,11); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_12)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,12); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_13)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,13); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_14)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,14); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_15)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,15); }
HL_PRIM realtime_bytes *HL_NAME(native_bytes_invoke_16)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, vbyte *length_symbol, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14, vdynamic *a15 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15}; return haxeon_native_bytes_invoke(library,symbol,signature,ownership,release,length_symbol,nullable,arguments,16); }

HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_0)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable ) { return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,NULL,0); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_1)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0 ) { vdynamic *arguments[] = {a0}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,1); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_2)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1 ) { vdynamic *arguments[] = {a0,a1}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,2); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_3)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2 ) { vdynamic *arguments[] = {a0,a1,a2}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,3); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_4)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3 ) { vdynamic *arguments[] = {a0,a1,a2,a3}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,4); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_5)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,5); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_6)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,6); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_7)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,7); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_8)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,8); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_9)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,9); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_10)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,10); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_11)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,11); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_12)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,12); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_13)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,13); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_14)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,14); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_15)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,15); }
HL_PRIM haxeon_native_pointer *HL_NAME(native_pointer_invoke_16)( vbyte *library, vbyte *symbol, vbyte *signature, vbyte *ownership, vbyte *release, bool nullable, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14, vdynamic *a15 ) { vdynamic *arguments[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15}; return haxeon_native_pointer_invoke(library,symbol,signature,ownership,release,nullable,arguments,16); }

HL_PRIM vdynamic *HL_NAME(native_invoke_0)( vbyte *library, vbyte *symbol, vbyte *signature ) { return haxeon_native_invoke(library,symbol,signature,NULL,0); }
HL_PRIM vdynamic *HL_NAME(native_invoke_1)( vbyte *library, vbyte *symbol, vbyte *signature, vdynamic *a0 ) { vdynamic *a[] = {a0}; return haxeon_native_invoke(library,symbol,signature,a,1); }
HL_PRIM vdynamic *HL_NAME(native_invoke_2)( vbyte *library, vbyte *symbol, vbyte *signature, vdynamic *a0, vdynamic *a1 ) { vdynamic *a[] = {a0,a1}; return haxeon_native_invoke(library,symbol,signature,a,2); }
HL_PRIM vdynamic *HL_NAME(native_invoke_3)( vbyte *library, vbyte *symbol, vbyte *signature, vdynamic *a0, vdynamic *a1, vdynamic *a2 ) { vdynamic *a[] = {a0,a1,a2}; return haxeon_native_invoke(library,symbol,signature,a,3); }
HL_PRIM vdynamic *HL_NAME(native_invoke_4)( vbyte *library, vbyte *symbol, vbyte *signature, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3 ) { vdynamic *a[] = {a0,a1,a2,a3}; return haxeon_native_invoke(library,symbol,signature,a,4); }
HL_PRIM vdynamic *HL_NAME(native_invoke_5)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4 ) { vdynamic *a[] = {a0,a1,a2,a3,a4}; return haxeon_native_invoke(l,s,g,a,5); }
HL_PRIM vdynamic *HL_NAME(native_invoke_6)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5}; return haxeon_native_invoke(l,s,g,a,6); }
HL_PRIM vdynamic *HL_NAME(native_invoke_7)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6}; return haxeon_native_invoke(l,s,g,a,7); }
HL_PRIM vdynamic *HL_NAME(native_invoke_8)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7}; return haxeon_native_invoke(l,s,g,a,8); }
HL_PRIM vdynamic *HL_NAME(native_invoke_9)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8}; return haxeon_native_invoke(l,s,g,a,9); }
HL_PRIM vdynamic *HL_NAME(native_invoke_10)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9}; return haxeon_native_invoke(l,s,g,a,10); }
HL_PRIM vdynamic *HL_NAME(native_invoke_11)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10}; return haxeon_native_invoke(l,s,g,a,11); }
HL_PRIM vdynamic *HL_NAME(native_invoke_12)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11}; return haxeon_native_invoke(l,s,g,a,12); }
HL_PRIM vdynamic *HL_NAME(native_invoke_13)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12}; return haxeon_native_invoke(l,s,g,a,13); }
HL_PRIM vdynamic *HL_NAME(native_invoke_14)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13}; return haxeon_native_invoke(l,s,g,a,14); }
HL_PRIM vdynamic *HL_NAME(native_invoke_15)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14}; return haxeon_native_invoke(l,s,g,a,15); }
HL_PRIM vdynamic *HL_NAME(native_invoke_16)( vbyte *l, vbyte *s, vbyte *g, vdynamic *a0, vdynamic *a1, vdynamic *a2, vdynamic *a3, vdynamic *a4, vdynamic *a5, vdynamic *a6, vdynamic *a7, vdynamic *a8, vdynamic *a9, vdynamic *a10, vdynamic *a11, vdynamic *a12, vdynamic *a13, vdynamic *a14, vdynamic *a15 ) { vdynamic *a[] = {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15}; return haxeon_native_invoke(l,s,g,a,16); }

HL_PRIM int HL_NAME(native_last_error)( vbyte *output, int capacity ) {
	int length = (int)strlen(haxeon_native_error);
	if( output == NULL || capacity < length ) return -length;
	if( length > 0 ) memcpy(output,haxeon_native_error,(size_t)length);
	return length;
}
