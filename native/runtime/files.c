extern vbyte *hl_sys_get_cwd( void );
extern void hl_sys_profile_span( int code, uchar *name );
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
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
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

HL_PRIM void HL_NAME(__sys_profile_span)( int code, vstring *name ) {
	hl_sys_profile_span(code,name == NULL ? NULL : name->bytes);
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
		hl_gc_store_ref(&target[index],realtime_string_from_platform(source[index]),hl_string_type);
	return result;
}

static void realtime_directory_entries_reserve( varray **array, vstring ***current, int *capacity, int needed, int used ) {
	if( needed <= *capacity ) return;
	int next_capacity = *capacity == 0 ? 32 : *capacity * 2;
	while( next_capacity < needed ) next_capacity *= 2;
	varray *next = hl_alloc_array(hl_string_type,next_capacity);
	vstring **storage = hl_aptr(next,vstring *);
	if( *current != NULL ) memcpy(storage,*current,(size_t)used * sizeof(vstring*));
	*array = next;
	*current = storage;
	*capacity = next_capacity;
}

#ifndef HL_WIN
static bool realtime_posix_entry_is_directory( DIR *directory, const struct dirent *entry ) {
#if defined(DT_DIR) && defined(DT_UNKNOWN) && defined(DT_LNK)
	if( entry->d_type == DT_DIR ) return true;
	if( entry->d_type != DT_UNKNOWN && entry->d_type != DT_LNK ) return false;
#endif
	struct stat info;
	return fstatat(dirfd(directory),entry->d_name,&info,0) == 0 && S_ISDIR(info.st_mode);
}
#endif

/* Returns alternating name and "d"/"f" markers so callers can classify a
   listing without issuing one filesystem query per child. */
HL_PRIM varray *HL_NAME(__sys_read_dir_entries)( vstring *path ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	varray *result = NULL;
	vstring **current = NULL;
	int capacity = 0;
	int position = 0;
	vstring *directory_marker;
	vstring *file_marker;
#ifdef HL_WIN
	directory_marker = realtime_string_from_platform((vbyte*)L"d");
	file_marker = realtime_string_from_platform((vbyte*)L"f");
	int path_length = (int)pstrlen((pchar*)argument);
	hl_buffer *pattern = hl_alloc_buffer();
	hl_buffer_str(pattern,(pchar*)argument);
	if( path_length != 0 && ((pchar*)argument)[path_length-1] != '/' && ((pchar*)argument)[path_length-1] != '\\' )
		hl_buffer_str(pattern,USTR("/*.*"));
	else
		hl_buffer_str(pattern,USTR("*.*"));
	HANDLE handle;
	WIN32_FIND_DATAW entry;
	handle = FindFirstFileW((wchar_t*)hl_buffer_content(pattern,NULL),&entry);
	if( handle == INVALID_HANDLE_VALUE ) {
		free(owned);
		return NULL;
	}
	do {
		if( entry.cFileName[0] == L'.' && (entry.cFileName[1] == 0 || (entry.cFileName[1] == L'.' && entry.cFileName[2] == 0)) ) continue;
		realtime_directory_entries_reserve(&result,&current,&capacity,position + 2,position);
		current[position++] = realtime_string_from_platform((vbyte*)entry.cFileName);
		current[position++] = (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? directory_marker : file_marker;
	} while( FindNextFileW(handle,&entry) );
	FindClose(handle);
#else
	directory_marker = realtime_string_from_platform((vbyte*)"d");
	file_marker = realtime_string_from_platform((vbyte*)"f");
	DIR *directory = opendir((const char*)argument);
	if( directory == NULL ) {
		free(owned);
		return NULL;
	}
	struct dirent *entry;
	while( (entry = readdir(directory)) != NULL ) {
		if( entry->d_name[0] == '.' && (entry->d_name[1] == 0 || (entry->d_name[1] == '.' && entry->d_name[2] == 0)) ) continue;
		bool is_directory = realtime_posix_entry_is_directory(directory,entry);
		realtime_directory_entries_reserve(&result,&current,&capacity,position + 2,position);
		current[position++] = realtime_string_from_platform((vbyte*)entry->d_name);
		current[position++] = is_directory ? directory_marker : file_marker;
	}
	closedir(directory);
#endif
	free(owned);
	if( result == NULL ) result = hl_alloc_array(hl_string_type,0);
	result->size = position;
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

/* The loaded bytecode path, independent of the HashLink executable's installation. */
extern vbyte *hl_sys_hl_file(void);
HL_PRIM vstring *HL_NAME(__sys_program_path)(void) {
  return realtime_string_from_platform(hl_sys_hl_file());
}
