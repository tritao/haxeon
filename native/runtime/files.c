extern vbyte *hl_sys_get_cwd( void );
extern vbyte *hl_sys_full_path( vbyte *path );
extern vbyte *hl_sys_exe_path( void );
extern bool hl_sys_exists( vbyte *path );
extern bool hl_sys_is_dir( vbyte *path );
extern bool hl_sys_set_cwd( vbyte *path );
extern bool hl_sys_create_dir( vbyte *path, int mode );
extern bool hl_sys_remove_dir( vbyte *path );
extern bool hl_sys_delete( vbyte *path );
extern bool hl_sys_rename( vbyte *path, vbyte *new_path );
extern varray *hl_sys_read_dir( vbyte *path );
extern varray *hl_sys_stat( vbyte *path );

#ifdef HL_WIN
#include <wchar.h>
#endif

static char *realtime_utf8_copy( vstring *value ) {
	const char *utf8 = value == NULL ? "" : realtime_string_utf8(value);
	char *result = (char *)malloc(strlen(utf8) + 1);
	if( result == NULL ) hl_error("Could not allocate UTF-8 string");
	strcpy(result,utf8);
	return result;
}

static vbyte *realtime_platform_argument( vstring *value, char **owned ) {
#ifdef HL_WIN
	*owned = NULL;
	return (vbyte *)realtime_string_data(value);
#else
	*owned = realtime_utf8_copy(value);
	return (vbyte *)*owned;
#endif
}

static vstring *realtime_string_from_platform( vbyte *value ) {
	if( value == NULL ) return NULL;
#ifdef HL_WIN
	return realtime_string_of_ustr((const uchar *)value);
#else
	return realtime_string_from_utf8((const char *)value);
#endif
}

HL_PRIM vstring *HL_NAME(__sys_get_cwd)( void ) {
	return realtime_string_from_platform(hl_sys_get_cwd());
}

HL_PRIM vstring *HL_NAME(__sys_full_path)( vstring *path ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	vbyte *result = hl_sys_full_path(argument);
	free(owned);
	return realtime_string_from_platform(result);
}

HL_PRIM vstring *HL_NAME(__sys_exe_path)( void ) {
	return realtime_string_from_platform(hl_sys_exe_path());
}

#define REALTIME_PATH_BOOL(name) \
	HL_PRIM bool HL_NAME(__sys_##name)( vstring *path ) { \
		char *owned; \
		vbyte *argument = realtime_platform_argument(path,&owned); \
		bool result = hl_sys_##name(argument); \
		free(owned); \
		return result; \
	}

REALTIME_PATH_BOOL(exists)
REALTIME_PATH_BOOL(is_dir)
REALTIME_PATH_BOOL(set_cwd)
REALTIME_PATH_BOOL(remove_dir)
REALTIME_PATH_BOOL(delete)

HL_PRIM bool HL_NAME(__sys_create_dir)( vstring *path, int mode ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	bool result = hl_sys_create_dir(argument,mode);
	free(owned);
	return result;
}

HL_PRIM bool HL_NAME(__sys_rename)( vstring *path, vstring *new_path ) {
	char *owned_path, *owned_new_path;
	vbyte *path_argument = realtime_platform_argument(path,&owned_path);
	vbyte *new_path_argument = realtime_platform_argument(new_path,&owned_new_path);
	bool result = hl_sys_rename(path_argument,new_path_argument);
	free(owned_path);
	free(owned_new_path);
	return result;
}

HL_PRIM varray *HL_NAME(__sys_read_dir)( vstring *path ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	varray *platform = hl_sys_read_dir(argument);
	free(owned);
	if( platform == NULL ) return NULL;
	varray *result = hl_alloc_array(hl_string_type,platform->size);
	vbyte **source = hl_aptr(platform,vbyte *);
	vstring **target = hl_aptr(result,vstring *);
	for( int index = 0; index < platform->size; index++ )
		target[index] = realtime_string_from_platform(source[index]);
	return result;
}

HL_PRIM varray *HL_NAME(__sys_metadata)( vstring *path ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	varray *result = hl_sys_stat(argument);
	free(owned);
	return result;
}

HL_PRIM void HL_NAME(__file_save_bytes)( vstring *path, realtime_bytes *bytes ) {
#ifdef HL_WIN
	FILE *file = _wfopen((const wchar_t *)realtime_string_data(path),L"wb");
#else
	char *path_utf8 = realtime_utf8_copy(path);
	FILE *file = fopen(path_utf8, "wb");
	free(path_utf8);
#endif
	if( file == NULL ) hl_error("Could not open output file");
	if( bytes->length > 0 && fwrite(bytes->data, 1, (size_t)bytes->length, file) != (size_t)bytes->length ) {
		fclose(file);
		hl_error("Could not write output file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close output file");
}

HL_PRIM void HL_NAME(__file_save_content)( vstring *path, vstring *content ) {
#ifdef HL_WIN
	FILE *file = _wfopen((const wchar_t *)realtime_string_data(path),L"wb");
#else
	char *owned_path = realtime_utf8_copy(path);
	FILE *file = fopen(owned_path, "wb");
	free(owned_path);
#endif
	const char *utf8 = content == NULL ? "" : realtime_string_utf8(content);
	if( file == NULL ) hl_error("Could not open output file");
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8, 1, length, file) != length ) {
		fclose(file);
		hl_error("Could not write output file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close output file");
}

HL_PRIM void HL_NAME(__file_append_content)( vstring *path, vstring *content ) {
#ifdef HL_WIN
	FILE *file = _wfopen((const wchar_t *)realtime_string_data(path),L"ab");
#else
	char *owned_path = realtime_utf8_copy(path);
	FILE *file = fopen(owned_path, "ab");
	free(owned_path);
#endif
	const char *utf8 = content == NULL ? "" : realtime_string_utf8(content);
	if( file == NULL ) hl_error("Could not open append file");
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8, 1, length, file) != length ) {
		fclose(file);
		hl_error("Could not append file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close append file");
}


static vbyte *realtime_file_read( vstring *path, int *length ) {
#ifdef HL_WIN
	FILE *file = _wfopen((const wchar_t *)realtime_string_data(path),L"rb");
#else
	char *path_utf8 = realtime_utf8_copy(path);
	FILE *file = fopen(path_utf8, "rb");
	free(path_utf8);
#endif
	if( file == NULL ) hl_error("Could not open source file");
	if( fseek(file, 0, SEEK_END) != 0 ) {
		fclose(file);
		hl_error("Could not seek source file");
	}
	long byte_length = ftell(file);
	if( byte_length > 0x7FFFFFFF ) {
		fclose(file);
		hl_error("Source file is too large");
	}
	if( byte_length < 0 || fseek(file, 0, SEEK_SET) != 0 ) {
		fclose(file);
		hl_error("Could not measure source file");
	}
	vbyte *data = (vbyte *)malloc((size_t)byte_length + 1);
	if( data == NULL ) {
		fclose(file);
		hl_error("Could not allocate source buffer");
	}
	if( fread(data, 1, (size_t)byte_length, file) != (size_t)byte_length ) {
		free(data);
		fclose(file);
		hl_error("Could not read source file");
	}
	fclose(file);
	data[byte_length] = 0;
	*length = (int)byte_length;
	return data;
}

HL_PRIM vstring *HL_NAME(__file_get_content)( vstring *path ) {
	int length;
	vbyte *data = realtime_file_read(path,&length);
	if( length > 0 && memchr(data,0,(size_t)length) != NULL ) {
		free(data);
		hl_error("HashLink String cannot contain NUL; use File.getBytes for binary data");
	}
	vstring *result = realtime_string_from_utf8((const char *)data);
	free(data);
	return result;
}

HL_PRIM realtime_bytes *HL_NAME(__file_get_bytes)( vstring *path ) {
	int length;
	vbyte *data = realtime_file_read(path,&length);
	realtime_bytes *result = realtime_bytes_make(length);
	if( length > 0 ) memcpy(result->data,data,(size_t)length);
	free(data);
	return result;
}
