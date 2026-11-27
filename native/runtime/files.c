extern vbyte *hl_sys_get_cwd( void );
extern void hl_sys_profile_span( int code, uchar *name );
extern void hl_sys_profile_event( int code, vbyte *data, int dataLen );
extern void hl_sys_profile_counter( uchar *name, double value );
extern void hl_sys_profile_frame( int kind, int frame_set );
extern vbyte *hl_sys_exe_path( void );
extern bool hl_sys_set_cwd( vbyte *path );

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

HL_PRIM void HL_NAME(__sys_profile_counter)( vstring *name, double value ) {
	hl_sys_profile_counter(name == NULL ? NULL : name->bytes,value);
}

HL_PRIM void HL_NAME(__sys_profile_frame)( int kind, int frame_set ) {
	hl_sys_profile_frame(kind,frame_set);
}

HL_PRIM void HL_NAME(__sys_thread_set_name)( vstring *name ) {
	hl_thread_set_name(hl_thread_current(),name == NULL ? "" : realtime_string_utf8(name));
}

HL_PRIM vstring *HL_NAME(__sys_get_cwd)( void ) {
	return realtime_string_from_platform(hl_sys_get_cwd());
}

HL_PRIM vstring *HL_NAME(__sys_exe_path)( void ) {
	return realtime_string_from_platform(hl_sys_exe_path());
}

HL_PRIM bool HL_NAME(__sys_set_cwd)( vstring *path ) {
	char *owned;
	vbyte *argument = realtime_platform_argument(path,&owned);
	bool result = hl_sys_set_cwd(argument);
	free(owned);
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

/* A file's version, for telling whether it was written between two looks: eight 32-bit integers written to `out`, the size
   (low, high), the modification and status-change times (seconds, nanoseconds; on Windows the last write's FILETIME halves and
   zeroes), the inode and the device. `path` is UTF-8 with a terminating zero. False when there is no file. */
HL_PRIM bool HL_NAME(__sys_file_version)( vbyte *path, vbyte *out ) {
	int values[8];
	memset(values, 0, sizeof(values));
#ifdef HL_WIN
	int length = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
	if( length <= 0 ) return false;
	wchar_t *wide = (wchar_t *)malloc(sizeof(wchar_t) * length);
	if( wide == NULL ) hl_error("Could not allocate path");
	MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, wide, length);
	WIN32_FILE_ATTRIBUTE_DATA data;
	BOOL found = GetFileAttributesExW(wide, GetFileExInfoStandard, &data);
	free(wide);
	if( !found ) return false;
	values[0] = (int)data.nFileSizeLow;
	values[1] = (int)data.nFileSizeHigh;
	values[2] = (int)data.ftLastWriteTime.dwHighDateTime;
	values[3] = (int)data.ftLastWriteTime.dwLowDateTime;
#else
	struct stat info;
	if( stat((const char *)path, &info) != 0 ) return false;
	values[0] = (int)((unsigned long long)info.st_size & 0xFFFFFFFFu);
	values[1] = (int)((unsigned long long)info.st_size >> 32);
#ifdef __APPLE__
	values[2] = (int)info.st_mtimespec.tv_sec;
	values[3] = (int)info.st_mtimespec.tv_nsec;
	values[4] = (int)info.st_ctimespec.tv_sec;
	values[5] = (int)info.st_ctimespec.tv_nsec;
#else
	values[2] = (int)info.st_mtim.tv_sec;
	values[3] = (int)info.st_mtim.tv_nsec;
	values[4] = (int)info.st_ctim.tv_sec;
	values[5] = (int)info.st_ctim.tv_nsec;
#endif
	values[6] = (int)info.st_ino;
	values[7] = (int)info.st_dev;
#endif
	memcpy(out, values, sizeof(values));
	return true;
}

extern void hl_gc_dump_memory( const char *filename );
extern void hl_gc_census_dump( const char *filename );

/* The collector takes a NUL-terminated UTF-8 path on every platform; taking a String here keeps that out of every caller. */
HL_PRIM void HL_NAME(__gc_dump_memory)( vstring *path ) {
	char *native_path = realtime_utf8_copy(path);
	hl_gc_dump_memory(native_path);
	free(native_path);
}

extern void hl_gc_stats( double *total_allocated, double *allocation_count, double *current_memory );

/* HashLink's GC counters, as hl.Gc.stats reads them: bytes allocated in total, allocations made, and current heap bytes. */
HL_PRIM varray *HL_NAME(__gc_stats)( void ) {
	double total = 0, count = 0, memory = 0;
	hl_gc_stats(&total, &count, &memory);
	varray *result = hl_alloc_array(&hlt_f64, 3);
	double *values = hl_aptr(result, double);
	values[0] = total;
	values[1] = count;
	values[2] = memory;
	return result;
}

HL_PRIM void HL_NAME(__gc_census_dump)( vstring *path ) {
	char *native_path = realtime_utf8_copy(path);
	hl_gc_census_dump(native_path);
	free(native_path);
}

extern vbyte *hl_sys_hl_file(void);
HL_PRIM vstring *HL_NAME(__sys_program_path)(void) {
  return realtime_string_from_platform(hl_sys_hl_file());
}
