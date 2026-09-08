#ifdef HL_WIN
#include <windows.h>

static vbyte *realtime_atomic_windows_error( DWORD error ) {
	wchar_t *message = NULL;
	DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL,error,0,(wchar_t *)&message,0,NULL);
	if( length == 0 ) return realtime_string_from_utf8("unknown Windows error");
	while( length > 0 && (message[length - 1] == L'\r' || message[length - 1] == L'\n') ) length--;
	message[length] = 0;
	vbyte *result = hl_copy_bytes((vbyte *)message,(int)((length + 1) * sizeof(wchar_t)));
	LocalFree(message);
	return result;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static vbyte *realtime_atomic_error( int error ) {
	return realtime_string_from_utf8(strerror(error));
}

static int realtime_sync_parent( const char *path ) {
	char *parent = strdup(path);
	if( parent == NULL ) return ENOMEM;
	char *slash = strrchr(parent,'/');
	if( slash == NULL ) strcpy(parent,".");
	else if( slash == parent ) slash[1] = 0;
	else *slash = 0;
	int descriptor = open(parent,O_RDONLY);
	free(parent);
	if( descriptor < 0 ) return errno;
	int result = fsync(descriptor) == 0 ? 0 : errno;
	if( close(descriptor) != 0 && result == 0 ) result = errno;
	return result;
}
#endif

/* Null means success; otherwise the returned string is the platform error. */
HL_PRIM vbyte *HL_NAME(__file_write_atomic)( vbyte *path, realtime_bytes *content, bool replace ) {
#ifdef HL_WIN
	if( content == NULL ) return realtime_string_from_utf8("content is null");
	const wchar_t *target = (const wchar_t *)path;
	DWORD attributes = GetFileAttributesW(target), error = ERROR_SUCCESS;
	bool target_exists = attributes != INVALID_FILE_ATTRIBUTES;
	if( target_exists && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ) return realtime_atomic_windows_error(ERROR_DIRECTORY);
	if( !target_exists && GetLastError() != ERROR_FILE_NOT_FOUND ) return realtime_atomic_windows_error(GetLastError());

	size_t target_length = wcslen(target);
	wchar_t *temporary = malloc((target_length + 64) * sizeof(wchar_t));
	if( temporary == NULL ) return realtime_atomic_windows_error(ERROR_NOT_ENOUGH_MEMORY);
	static LONG sequence = 0;
	HANDLE file = INVALID_HANDLE_VALUE;
	for( int attempt = 0; attempt < 128 && file == INVALID_HANDLE_VALUE; attempt++ ) {
		_snwprintf(temporary,target_length + 64,L"%ls.tmp.%lu.%ld",target,
			(unsigned long)GetCurrentProcessId(),(long)InterlockedIncrement(&sequence));
		file = CreateFileW(temporary,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
		if( file == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_EXISTS ) break;
	}
	if( file == INVALID_HANDLE_VALUE ) error = GetLastError();
	int offset = 0;
	while( error == ERROR_SUCCESS && offset < content->length ) {
		DWORD written = 0, remaining = (DWORD)(content->length - offset);
		if( !WriteFile(file,content->data + offset,remaining,&written,NULL) || written == 0 ) {
			error = GetLastError();
			if( error == ERROR_SUCCESS ) error = ERROR_WRITE_FAULT;
			break;
		}
		offset += (int)written;
	}
	if( error == ERROR_SUCCESS && !FlushFileBuffers(file) ) error = GetLastError();
	if( file != INVALID_HANDLE_VALUE && !CloseHandle(file) && error == ERROR_SUCCESS ) error = GetLastError();
	if( error == ERROR_SUCCESS ) {
		if( replace && target_exists ) {
			if( !ReplaceFileW(target,temporary,NULL,REPLACEFILE_WRITE_THROUGH,NULL,NULL) ) error = GetLastError();
		} else {
			DWORD flags = MOVEFILE_WRITE_THROUGH | (replace ? MOVEFILE_REPLACE_EXISTING : 0);
			if( !MoveFileExW(temporary,target,flags) ) error = GetLastError();
		}
	}
	if( error != ERROR_SUCCESS ) DeleteFileW(temporary);
	vbyte *result = error == ERROR_SUCCESS ? NULL : realtime_atomic_windows_error(error);
	free(temporary);
	return result;
#else
	if( content == NULL ) return realtime_string_from_utf8("content is null");
	char *target = realtime_utf8_copy(path);
	char *temporary = malloc(strlen(target) + 16);
	if( temporary == NULL ) { free(target); return realtime_atomic_error(ENOMEM); }
	sprintf(temporary,"%s.XXXXXX",target);

	struct stat metadata;
	int target_status = stat(target,&metadata), error = 0;
	if( target_status != 0 && errno != ENOENT ) error = errno;
	else if( target_status == 0 && !S_ISREG(metadata.st_mode) ) error = EINVAL;

	int descriptor = error == 0 ? mkstemp(temporary) : -1;
	if( descriptor < 0 && error == 0 ) error = errno;
	if( error == 0 && target_status == 0 && fchmod(descriptor,metadata.st_mode & 07777) != 0 ) error = errno;
	int offset = 0;
	while( error == 0 && offset < content->length ) {
		ssize_t written = write(descriptor,content->data + offset,(size_t)(content->length - offset));
		if( written < 0 && errno == EINTR ) continue;
		if( written <= 0 ) { error = written < 0 ? errno : EIO; break; }
		offset += (int)written;
	}
	if( error == 0 && fsync(descriptor) != 0 ) error = errno;
	if( descriptor >= 0 && close(descriptor) != 0 && error == 0 ) error = errno;

	if( error == 0 && replace ) {
		if( rename(temporary,target) != 0 ) error = errno;
	} else if( error == 0 ) {
		if( link(temporary,target) != 0 ) error = errno;
		else if( unlink(temporary) != 0 ) error = errno;
	}
	if( error == 0 ) error = realtime_sync_parent(target);
	if( error != 0 && descriptor >= 0 ) unlink(temporary);

	vbyte *result = error == 0 ? NULL : realtime_atomic_error(error);
	free(temporary);
	free(target);
	return result;
#endif
}
