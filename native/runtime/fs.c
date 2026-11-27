/* std.fs's natives: files and directories by path, with the system's own calls. Each answers its value, or a failure
   whose kind (`__fs_error`), system code and message std.fs reads back on the same thread before anything else runs on
   it. The kinds are std.fs.FileError's cases, in their order. */

#if defined(_MSC_VER)
#define REALTIME_FS_TLS __declspec(thread)
#else
#define REALTIME_FS_TLS _Thread_local
#endif
#ifndef HL_WIN
#include <fcntl.h>
#endif

enum {
	REALTIME_FS_OK,
	REALTIME_FS_NOT_FOUND,
	REALTIME_FS_ALREADY_EXISTS,
	REALTIME_FS_NOT_EMPTY,
	REALTIME_FS_NOT_A_DIRECTORY,
	REALTIME_FS_IS_A_DIRECTORY,
	REALTIME_FS_PERMISSION_DENIED,
	REALTIME_FS_ESCAPES_ROOT,
	REALTIME_FS_UNSUPPORTED,
	REALTIME_FS_IO
};

/* What a listing or metadata says an entry is: std.fs.EntryKind's cases, in their order. */
enum { REALTIME_FS_FILE, REALTIME_FS_DIRECTORY, REALTIME_FS_LINK, REALTIME_FS_OTHER };

static REALTIME_FS_TLS int realtime_fs_kind;
static REALTIME_FS_TLS int realtime_fs_code;

#ifdef HL_WIN
static int realtime_fs_kind_of( DWORD error ) {
	switch( error ) {
	case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_DRIVE: case ERROR_BAD_NETPATH:
	case ERROR_BAD_NET_NAME:
		return REALTIME_FS_NOT_FOUND;
	case ERROR_FILE_EXISTS: case ERROR_ALREADY_EXISTS:
		return REALTIME_FS_ALREADY_EXISTS;
	case ERROR_DIR_NOT_EMPTY:
		return REALTIME_FS_NOT_EMPTY;
	case ERROR_DIRECTORY:
		return REALTIME_FS_NOT_A_DIRECTORY;
	case ERROR_ACCESS_DENIED: case ERROR_WRITE_PROTECT: case ERROR_PRIVILEGE_NOT_HELD:
		return REALTIME_FS_PERMISSION_DENIED;
	default:
		return REALTIME_FS_IO;
	}
}

static bool realtime_fs_fail( DWORD error ) {
	realtime_fs_code = (int)error;
	realtime_fs_kind = realtime_fs_kind_of(error);
	return false;
}

static DWORD realtime_fs_attributes( vstring *path ) {
	return GetFileAttributesW((const wchar_t *)realtime_string_data(path));
}

static bool realtime_fs_is_directory( vstring *path ) {
	DWORD attributes = realtime_fs_attributes(path);
	return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}
#else
static int realtime_fs_kind_of( int error ) {
	switch( error ) {
	case ENOENT:
		return REALTIME_FS_NOT_FOUND;
	case EEXIST:
		return REALTIME_FS_ALREADY_EXISTS;
	case ENOTEMPTY:
		return REALTIME_FS_NOT_EMPTY;
	case ENOTDIR:
		return REALTIME_FS_NOT_A_DIRECTORY;
	case EISDIR:
		return REALTIME_FS_IS_A_DIRECTORY;
	case EACCES: case EPERM: case EROFS:
		return REALTIME_FS_PERMISSION_DENIED;
	default:
		return REALTIME_FS_IO;
	}
}

static bool realtime_fs_fail( int error ) {
	realtime_fs_code = error;
	realtime_fs_kind = realtime_fs_kind_of(error);
	return false;
}

static bool realtime_fs_is_directory( const char *path ) {
	struct stat info;
	return stat(path,&info) == 0 && S_ISDIR(info.st_mode);
}
#endif

static void realtime_fs_succeed( void ) {
	realtime_fs_kind = REALTIME_FS_OK;
	realtime_fs_code = 0;
}

/* A file operation that fails on a directory says so, whatever the system's code: Windows answers "access denied" and
   macOS "operation not permitted" where Linux answers EISDIR. */
#ifdef HL_WIN
static bool realtime_fs_fail_file( DWORD error, vstring *path ) {
	realtime_fs_fail(error);
	if( realtime_fs_kind != REALTIME_FS_NOT_FOUND && realtime_fs_is_directory(path) ) realtime_fs_kind = REALTIME_FS_IS_A_DIRECTORY;
	return false;
}
#else
static bool realtime_fs_fail_file( int error, const char *path ) {
	realtime_fs_fail(error);
	if( realtime_fs_kind != REALTIME_FS_NOT_FOUND && realtime_fs_is_directory(path) ) realtime_fs_kind = REALTIME_FS_IS_A_DIRECTORY;
	return false;
}
#endif

HL_PRIM int HL_NAME(__fs_error)( void ) {
	return realtime_fs_kind;
}
DEFINE_PRIM(_I32,__fs_error,_NO_ARG);

HL_PRIM int HL_NAME(__fs_error_code)( void ) {
	return realtime_fs_code;
}
DEFINE_PRIM(_I32,__fs_error_code,_NO_ARG);

/* The system's description of the last failure's code. */
HL_PRIM vstring *HL_NAME(__fs_error_message)( void ) {
#ifdef HL_WIN
	return realtime_atomic_windows_error((DWORD)realtime_fs_code);
#else
	return realtime_string_from_utf8(strerror(realtime_fs_code));
#endif
}
DEFINE_PRIM(_STRING,__fs_error_message,_NO_ARG);

/* The whole file, or null. */
HL_PRIM realtime_bytes *HL_NAME(__fs_read)( vstring *path ) {
#ifdef HL_WIN
	const wchar_t *wide = (const wchar_t *)realtime_string_data(path);
	HANDLE file = INVALID_HANDLE_VALUE;
	for( int attempt = 0;; attempt++ ) {
		file = CreateFileW(wide,GENERIC_READ,FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,NULL,OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL,NULL);
		if( file != INVALID_HANDLE_VALUE ) break;
		DWORD error = GetLastError();
		if( !realtime_atomic_transient(error) || realtime_fs_is_directory(path) || attempt == 20 ) {
			realtime_fs_fail_file(error,path);
			return NULL;
		}
		Sleep(attempt < 5 ? 10 : 50);
	}
	LARGE_INTEGER size;
	if( !GetFileSizeEx(file,&size) ) {
		DWORD error = GetLastError();
		CloseHandle(file);
		realtime_fs_fail(error);
		return NULL;
	}
	if( size.QuadPart > 0x7FFFFFFF ) {
		CloseHandle(file);
		realtime_fs_fail(ERROR_FILE_TOO_LARGE);
		return NULL;
	}
	realtime_bytes *result = realtime_bytes_make((int)size.QuadPart);
	int used = 0;
	while( used < result->length ) {
		DWORD got = 0;
		if( !ReadFile(file,result->data + used,(DWORD)(result->length - used),&got,NULL) ) {
			DWORD error = GetLastError();
			CloseHandle(file);
			realtime_fs_fail(error);
			return NULL;
		}
		if( got == 0 ) break;
		used += (int)got;
	}
	CloseHandle(file);
	result->length = used;
#else
	char *native = realtime_utf8_copy(path);
	int descriptor = open(native,O_RDONLY | O_CLOEXEC);
	if( descriptor < 0 ) {
		realtime_fs_fail(errno);
		free(native);
		return NULL;
	}
	free(native);
	struct stat info;
	if( fstat(descriptor,&info) != 0 ) {
		int error = errno;
		close(descriptor);
		realtime_fs_fail(error);
		return NULL;
	}
	if( S_ISDIR(info.st_mode) ) {
		close(descriptor);
		realtime_fs_fail(EISDIR);
		return NULL;
	}
	/* The measured size is only a first capacity: /proc files and pipes report 0, so read to the end. */
	size_t capacity = info.st_size > 0 ? (size_t)info.st_size : 4096, used = 0;
	vbyte *data = (vbyte *)malloc(capacity);
	if( data == NULL ) {
		close(descriptor);
		realtime_fs_fail(ENOMEM);
		return NULL;
	}
	for(;;) {
		if( used == capacity ) {
			if( capacity >= 0x40000000 ) {
				free(data);
				close(descriptor);
				realtime_fs_fail(EFBIG);
				return NULL;
			}
			vbyte *grown = (vbyte *)realloc(data,capacity * 2);
			if( grown == NULL ) {
				free(data);
				close(descriptor);
				realtime_fs_fail(ENOMEM);
				return NULL;
			}
			data = grown;
			capacity *= 2;
		}
		ssize_t got = read(descriptor,data + used,capacity - used);
		if( got < 0 && errno == EINTR ) continue;
		if( got < 0 ) {
			int error = errno;
			free(data);
			close(descriptor);
			realtime_fs_fail(error);
			return NULL;
		}
		if( got == 0 ) break;
		used += (size_t)got;
	}
	close(descriptor);
	if( used > 0x7FFFFFFF ) {
		free(data);
		realtime_fs_fail(EFBIG);
		return NULL;
	}
	/* The bytes adopt the buffer, which they free with free() as they do their own. */
	realtime_bytes *result = realtime_bytes_make(0);
	if( used == 0 ) free(data);
	else {
		result->data = data;
		result->length = (int)used;
	}
#endif
	realtime_fs_succeed();
	return result;
}
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__fs_read,_STRING);

/* How `__fs_write` opens the file: replacing what it holds, adding to its end, or only when nothing is there. */
enum { REALTIME_FS_REPLACE, REALTIME_FS_APPEND, REALTIME_FS_CREATE };

HL_PRIM bool HL_NAME(__fs_write)( vstring *path, realtime_bytes *content, int mode ) {
#ifdef HL_WIN
	const wchar_t *wide = (const wchar_t *)realtime_string_data(path);
	DWORD access = mode == REALTIME_FS_APPEND ? FILE_APPEND_DATA : GENERIC_WRITE;
	DWORD disposition = mode == REALTIME_FS_REPLACE ? CREATE_ALWAYS : mode == REALTIME_FS_APPEND ? OPEN_ALWAYS : CREATE_NEW;
	HANDLE file = INVALID_HANDLE_VALUE;
	for( int attempt = 0;; attempt++ ) {
		file = CreateFileW(wide,access,FILE_SHARE_READ | FILE_SHARE_DELETE,NULL,disposition,FILE_ATTRIBUTE_NORMAL,NULL);
		if( file != INVALID_HANDLE_VALUE ) break;
		DWORD error = GetLastError();
		if( !realtime_atomic_transient(error) || realtime_fs_is_directory(path) || attempt == 20 )
			return realtime_fs_fail_file(error,path);
		Sleep(attempt < 5 ? 10 : 50);
	}
	int offset = 0;
	while( offset < content->length ) {
		DWORD written = 0;
		if( !WriteFile(file,content->data + offset,(DWORD)(content->length - offset),&written,NULL) || written == 0 ) {
			DWORD error = GetLastError();
			CloseHandle(file);
			return realtime_fs_fail(error == ERROR_SUCCESS ? ERROR_WRITE_FAULT : error);
		}
		offset += (int)written;
	}
	if( !CloseHandle(file) ) return realtime_fs_fail(GetLastError());
#else
	char *native = realtime_utf8_copy(path);
	int flags = O_WRONLY | O_CREAT | O_CLOEXEC
		| (mode == REALTIME_FS_REPLACE ? O_TRUNC : mode == REALTIME_FS_APPEND ? O_APPEND : O_EXCL);
	int descriptor = open(native,flags,0666);
	if( descriptor < 0 ) {
		bool result = realtime_fs_fail_file(errno,native);
		free(native);
		return result;
	}
	free(native);
	int offset = 0;
	while( offset < content->length ) {
		ssize_t written = write(descriptor,content->data + offset,(size_t)(content->length - offset));
		if( written < 0 && errno == EINTR ) continue;
		if( written <= 0 ) {
			int error = written < 0 ? errno : EIO;
			close(descriptor);
			return realtime_fs_fail(error);
		}
		offset += (int)written;
	}
	if( close(descriptor) != 0 ) return realtime_fs_fail(errno);
#endif
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_write,_STRING _ABSTRACT(realtime_bytes) _I32);

HL_PRIM bool HL_NAME(__fs_write_atomic)( vstring *path, realtime_bytes *content, bool replace ) {
	int error = realtime_atomic_write(path,content,replace);
	if( error == 0 ) {
		realtime_fs_succeed();
		return true;
	}
#ifdef HL_WIN
	if( error == ERROR_DIRECTORY ) error = ERROR_ACCESS_DENIED;
	return realtime_fs_fail_file((DWORD)error,path);
#else
	char *native = realtime_utf8_copy(path);
	bool result = realtime_fs_fail_file(error,native);
	free(native);
	return result;
#endif
}
DEFINE_PRIM(_BOOL,__fs_write_atomic,_STRING _ABSTRACT(realtime_bytes) _BOOL);

/* Fills `out` with what is at `path`: its kind (std.fs.EntryKind) as an Int32 at 0, its size in bytes as an Int64 at 8,
   and its last modification as Unix seconds, a Float64 at 16. A symbolic link is described itself, not what it points
   to, unless `follow`. */
HL_PRIM bool HL_NAME(__fs_metadata)( vstring *path, bool follow, realtime_bytes *out ) {
	int kind;
	int64_t size;
	double modified;
#ifdef HL_WIN
	const wchar_t *wide = (const wchar_t *)realtime_string_data(path);
	DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | (follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
	HANDLE file = CreateFileW(wide,FILE_READ_ATTRIBUTES,FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,NULL,
		OPEN_EXISTING,flags,NULL);
	if( file == INVALID_HANDLE_VALUE ) return realtime_fs_fail(GetLastError());
	FILE_BASIC_INFO basic;
	FILE_STANDARD_INFO standard;
	FILE_ATTRIBUTE_TAG_INFO tag;
	if( !GetFileInformationByHandleEx(file,FileBasicInfo,&basic,sizeof(basic))
		|| !GetFileInformationByHandleEx(file,FileStandardInfo,&standard,sizeof(standard))
		|| !GetFileInformationByHandleEx(file,FileAttributeTagInfo,&tag,sizeof(tag)) ) {
		DWORD error = GetLastError();
		CloseHandle(file);
		return realtime_fs_fail(error);
	}
	CloseHandle(file);
	bool link = !follow && (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
		&& (tag.ReparseTag == IO_REPARSE_TAG_SYMLINK || tag.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT);
	kind = link ? REALTIME_FS_LINK : standard.Directory ? REALTIME_FS_DIRECTORY : REALTIME_FS_FILE;
	size = kind == REALTIME_FS_FILE ? (int64_t)standard.EndOfFile.QuadPart : 0;
	/* FILETIME counts 100 ns from 1601; Unix seconds count from 1970. */
	modified = (double)(basic.LastWriteTime.QuadPart - 116444736000000000LL) / 1e7;
#else
	char *native = realtime_utf8_copy(path);
	struct stat info;
	int status = follow ? stat(native,&info) : lstat(native,&info);
	free(native);
	if( status != 0 ) return realtime_fs_fail(errno);
	kind = S_ISREG(info.st_mode) ? REALTIME_FS_FILE : S_ISDIR(info.st_mode) ? REALTIME_FS_DIRECTORY
		: S_ISLNK(info.st_mode) ? REALTIME_FS_LINK : REALTIME_FS_OTHER;
	size = (int64_t)info.st_size;
#if defined(__APPLE__)
	modified = (double)info.st_mtimespec.tv_sec + (double)info.st_mtimespec.tv_nsec / 1e9;
#else
	modified = (double)info.st_mtim.tv_sec + (double)info.st_mtim.tv_nsec / 1e9;
#endif
#endif
	if( out == NULL || out->length < 24 ) hl_error("metadata buffer is too small");
	int32_t kind32 = kind;
	memcpy(out->data,&kind32,4);
	memcpy(out->data + 8,&size,8);
	memcpy(out->data + 16,&modified,8);
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_metadata,_STRING _BOOL _ABSTRACT(realtime_bytes));

/* The entries of a directory as name and kind (std.fs.EntryKind, as a one-character string: "f", "d", "l", "o"), in the
   order the system lists them, without "." and "..". Null on failure. */
HL_PRIM varray *HL_NAME(__fs_list)( vstring *path ) {
	varray *result = NULL;
	vstring **current = NULL;
	int capacity = 0, position = 0;
	vstring *markers[4];
	markers[REALTIME_FS_FILE] = realtime_string_from_utf8("f");
	markers[REALTIME_FS_DIRECTORY] = realtime_string_from_utf8("d");
	markers[REALTIME_FS_LINK] = realtime_string_from_utf8("l");
	markers[REALTIME_FS_OTHER] = realtime_string_from_utf8("o");
#ifdef HL_WIN
	const wchar_t *wide = (const wchar_t *)realtime_string_data(path);
	DWORD attributes = GetFileAttributesW(wide);
	if( attributes == INVALID_FILE_ATTRIBUTES ) {
		realtime_fs_fail(GetLastError());
		return NULL;
	}
	if( (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ) {
		realtime_fs_fail(ERROR_DIRECTORY);
		return NULL;
	}
	size_t length = wcslen(wide);
	wchar_t *pattern = (wchar_t *)malloc((length + 3) * sizeof(wchar_t));
	if( pattern == NULL ) {
		realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
		return NULL;
	}
	memcpy(pattern,wide,length * sizeof(wchar_t));
	if( length > 0 && wide[length - 1] != L'/' && wide[length - 1] != L'\\' ) pattern[length++] = L'/';
	pattern[length++] = L'*';
	pattern[length] = 0;
	WIN32_FIND_DATAW entry;
	HANDLE handle = FindFirstFileExW(pattern,FindExInfoBasic,&entry,FindExSearchNameMatch,NULL,FIND_FIRST_EX_LARGE_FETCH);
	free(pattern);
	if( handle == INVALID_HANDLE_VALUE ) {
		DWORD error = GetLastError();
		if( error != ERROR_FILE_NOT_FOUND ) {
			realtime_fs_fail(error);
			return NULL;
		}
	} else {
		do {
			if( entry.cFileName[0] == L'.' && (entry.cFileName[1] == 0 || (entry.cFileName[1] == L'.' && entry.cFileName[2] == 0)) )
				continue;
			bool link = (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
				&& (entry.dwReserved0 == IO_REPARSE_TAG_SYMLINK || entry.dwReserved0 == IO_REPARSE_TAG_MOUNT_POINT);
			int kind = link ? REALTIME_FS_LINK : (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? REALTIME_FS_DIRECTORY
				: REALTIME_FS_FILE;
			realtime_directory_entries_reserve(&result,&current,&capacity,position + 2,position);
			current[position++] = realtime_string_from_platform((vbyte *)entry.cFileName);
			current[position++] = markers[kind];
		} while( FindNextFileW(handle,&entry) );
		DWORD error = GetLastError();
		FindClose(handle);
		if( error != ERROR_NO_MORE_FILES ) {
			realtime_fs_fail(error);
			return NULL;
		}
	}
#else
	char *native = realtime_utf8_copy(path);
	DIR *directory = opendir(native);
	if( directory == NULL ) {
		realtime_fs_fail(errno);
		free(native);
		return NULL;
	}
	free(native);
	for(;;) {
		errno = 0;
		struct dirent *entry = readdir(directory);
		if( entry == NULL ) {
			int error = errno;
			closedir(directory);
			if( error != 0 ) {
				realtime_fs_fail(error);
				return NULL;
			}
			break;
		}
		if( entry->d_name[0] == '.' && (entry->d_name[1] == 0 || (entry->d_name[1] == '.' && entry->d_name[2] == 0)) ) continue;
		int kind;
#ifdef DT_UNKNOWN
		if( entry->d_type != DT_UNKNOWN )
			kind = entry->d_type == DT_REG ? REALTIME_FS_FILE : entry->d_type == DT_DIR ? REALTIME_FS_DIRECTORY
				: entry->d_type == DT_LNK ? REALTIME_FS_LINK : REALTIME_FS_OTHER;
		else
#endif
		{
			struct stat info;
			if( fstatat(dirfd(directory),entry->d_name,&info,AT_SYMLINK_NOFOLLOW) != 0 ) continue;
			kind = S_ISREG(info.st_mode) ? REALTIME_FS_FILE : S_ISDIR(info.st_mode) ? REALTIME_FS_DIRECTORY
				: S_ISLNK(info.st_mode) ? REALTIME_FS_LINK : REALTIME_FS_OTHER;
		}
		realtime_directory_entries_reserve(&result,&current,&capacity,position + 2,position);
		current[position++] = realtime_string_from_utf8(entry->d_name);
		current[position++] = markers[kind];
	}
#endif
	if( result == NULL ) result = hl_alloc_array(hl_string_type,0);
	result->size = position;
	realtime_fs_succeed();
	return result;
}
DEFINE_PRIM(_ARR,__fs_list,_STRING);

/* Creates the directory `path`, whose parent must exist. */
HL_PRIM bool HL_NAME(__fs_create_directory)( vstring *path ) {
#ifdef HL_WIN
	if( !CreateDirectoryW((const wchar_t *)realtime_string_data(path),NULL) ) return realtime_fs_fail(GetLastError());
#else
	char *native = realtime_utf8_copy(path);
	int status = mkdir(native,0777);
	int error = errno;
	free(native);
	if( status != 0 ) return realtime_fs_fail(error);
#endif
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_create_directory,_STRING);

/* Deletes the file or symbolic link `path`; a link to a directory goes, not the directory. */
HL_PRIM bool HL_NAME(__fs_delete_file)( vstring *path ) {
#ifdef HL_WIN
	const wchar_t *wide = (const wchar_t *)realtime_string_data(path);
	DWORD attributes = GetFileAttributesW(wide);
	if( attributes == INVALID_FILE_ATTRIBUTES ) return realtime_fs_fail(GetLastError());
	bool directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
	if( directory && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 ) return realtime_fs_fail_file(ERROR_ACCESS_DENIED,path);
	/* A link to a directory is a directory entry on Windows, removed as one. */
	if( !(directory ? RemoveDirectoryW(wide) : DeleteFileW(wide)) ) return realtime_fs_fail_file(GetLastError(),path);
#else
	char *native = realtime_utf8_copy(path);
	if( unlink(native) != 0 ) {
		bool result = realtime_fs_fail_file(errno,native);
		free(native);
		return result;
	}
	free(native);
#endif
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_delete_file,_STRING);

/* Removes the empty directory `path`. */
HL_PRIM bool HL_NAME(__fs_delete_directory)( vstring *path ) {
#ifdef HL_WIN
	if( !RemoveDirectoryW((const wchar_t *)realtime_string_data(path)) ) return realtime_fs_fail(GetLastError());
#else
	char *native = realtime_utf8_copy(path);
	int status = rmdir(native);
	int error = errno;
	free(native);
	/* POSIX lets rmdir answer EEXIST for a directory that is not empty. */
	if( status != 0 ) return realtime_fs_fail(error == EEXIST ? ENOTEMPTY : error);
#endif
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_delete_directory,_STRING);

/* Moves `path` to `target`, replacing a file there. */
HL_PRIM bool HL_NAME(__fs_rename)( vstring *path, vstring *target ) {
#ifdef HL_WIN
	if( !MoveFileExW((const wchar_t *)realtime_string_data(path),(const wchar_t *)realtime_string_data(target),
		MOVEFILE_REPLACE_EXISTING) )
		return realtime_fs_fail(GetLastError());
#else
	char *from = realtime_utf8_copy(path), *to = realtime_utf8_copy(target);
	int status = rename(from,to);
	int error = errno;
	free(from);
	free(to);
	if( status != 0 ) return realtime_fs_fail(error);
#endif
	realtime_fs_succeed();
	return true;
}
DEFINE_PRIM(_BOOL,__fs_rename,_STRING _STRING);
