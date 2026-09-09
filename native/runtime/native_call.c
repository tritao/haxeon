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

HL_PRIM int HL_NAME(native_last_error)( vbyte *output, int capacity ) {
	int length = (int)strlen(haxeon_native_error);
	if( output == NULL || capacity < length ) return -length;
	if( length > 0 ) memcpy(output,haxeon_native_error,(size_t)length);
	return length;
}
