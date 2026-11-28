/* std.fs on the operating system: files and directories by path, either as the process sees them or confined to a
   directory (a root) that nothing reached through it can leave. Plain C over the system's own calls, so it builds and is
   tested without HashLink; fs.c binds it for std.fs.

   Both kinds of resolution share every operation. An operation opens what it acts on through `realtime_fs_open`, or
   names it as a place (a directory and a name in it) through `realtime_fs_place_of`; only those two differ:

   - for the process's own view (`root` NULL), a path is the system's: absolute, or against the working directory, with
     `..` and symbolic links followed;
   - for a root, a path is relative to it, and `..` is refused. Linux resolves it with openat2 and RESOLVE_BENEATH, macOS
     with O_RESOLVE_BENEATH, both in the kernel, so a symbolic link is followed only while it stays beneath the root.
     Windows opens by path and keeps the handle only when its final path is still beneath the root; it creates, deletes
     and renames by name relative to such a handle (NtCreateFile, SetFileInformationByHandle), so no path is walked
     again after the check. Other systems answer Unsupported for a root.

   Each operation answers true, or false after recording why (`realtime_fs_kind`, `realtime_fs_code`) on its thread. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <sys/stat.h>
#include <sys/types.h>
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__) && defined(__has_include)
#if __has_include(<linux/openat2.h>)
#include <linux/openat2.h>
#include <sys/syscall.h>
#if defined(SYS_openat2)
#define REALTIME_FS_OPENAT2 1
#endif
#endif
#endif
#if defined(__APPLE__) && !defined(ENOTCAPABLE)
/* Public SDK headers can lag the kernel; see XNU tests/vfs/resolve_beneath.c. */
#define ENOTCAPABLE 107
#endif
#endif

#if defined(_MSC_VER)
#define REALTIME_FS_TLS __declspec(thread)
#else
#define REALTIME_FS_TLS _Thread_local
#endif

/* Why an operation failed: std.fs.FileError's cases, in their order. */
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

/* What an entry is: std.fs.EntryKind's cases, in their order. */
enum { REALTIME_FS_FILE, REALTIME_FS_DIRECTORY, REALTIME_FS_LINK, REALTIME_FS_OTHER };

/* How a write opens its file: replacing what it holds, adding to its end, or only when nothing is there. */
enum { REALTIME_FS_REPLACE, REALTIME_FS_APPEND, REALTIME_FS_CREATE };

static REALTIME_FS_TLS int realtime_fs_kind;
static REALTIME_FS_TLS int realtime_fs_code;

/* The code of an Io failure that is not the system's: a file read as text holds a NUL character, which a String cannot. */
#define REALTIME_FS_TEXT_NUL (-1)

typedef struct {
	int kind;
	int64_t size;
	/* The last modification, in seconds since 1970-01-01 UTC. */
	double modified;
} realtime_fs_metadata;

/* Called once per entry of a listing, with its name (not NUL-terminated) and kind. */
typedef void (*realtime_fs_emit)( void *context, const void *name, int length, int kind );

static bool realtime_fs_succeed( void ) {
	realtime_fs_kind = REALTIME_FS_OK;
	realtime_fs_code = 0;
	return true;
}

static bool realtime_fs_refuse( int kind ) {
	realtime_fs_kind = kind;
	realtime_fs_code = 0;
	return false;
}

#ifdef _WIN32
typedef wchar_t realtime_fs_char;

/* A root: a handle on its directory, the directory's final path (`\\?\C:\...`), and its identity, by which a root whose
   path was replaced is told apart. */
typedef struct {
	HANDLE handle;
	wchar_t *path;
	DWORD volume;
	DWORD index_high;
	DWORD index_low;
} realtime_fs_directory;
#else
typedef char realtime_fs_char;

/* A root: a descriptor of its directory, or -1 once closed. */
typedef struct {
	int fd;
} realtime_fs_directory;
#endif

/* Whether a root may reach `path`, normalized by std.fs.Path: "." or names joined by "/", none of them ".." (nor, on
   Windows, holding ":", which names a drive or a stream). */
static bool realtime_fs_confined( const realtime_fs_char *path ) {
	if( path[0] == '/' ) return false;
	const realtime_fs_char *start = path;
	for( const realtime_fs_char *at = path;; at++ ) {
		if( *at == '/' || *at == 0 ) {
			if( at - start == 2 && start[0] == '.' && start[1] == '.' ) return false;
			if( *at == 0 ) return true;
			start = at + 1;
		}
#ifdef _WIN32
		if( *at == ':' || *at == '\\' ) return false;
#endif
	}
}

static bool realtime_fs_is_self( const realtime_fs_char *path ) {
	return path[0] == '.' && path[1] == 0;
}

#ifdef _WIN32
/* ------------------------------------------------------------------------------------------------ Windows */

#ifndef FILE_OPEN
#define FILE_OPEN 0x00000001
#endif
#ifndef FILE_CREATE
#define FILE_CREATE 0x00000002
#endif
#ifndef FILE_OVERWRITE
#define FILE_OVERWRITE 0x00000004
#endif
#ifndef FILE_DIRECTORY_FILE
#define FILE_DIRECTORY_FILE 0x00000001
#endif
#ifndef FILE_SYNCHRONOUS_IO_NONALERT
#define FILE_SYNCHRONOUS_IO_NONALERT 0x00000020
#endif
#ifndef FILE_NON_DIRECTORY_FILE
#define FILE_NON_DIRECTORY_FILE 0x00000040
#endif
#ifndef FILE_OPEN_REPARSE_POINT
#define FILE_OPEN_REPARSE_POINT 0x00200000
#endif
#ifndef FILE_OPEN_FOR_BACKUP_INTENT
#define FILE_OPEN_FOR_BACKUP_INTENT 0x00004000
#endif
#ifndef OBJ_CASE_INSENSITIVE
#define OBJ_CASE_INSENSITIVE 0x00000040
#endif

#define REALTIME_FS_SHARE_ALL (FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)

/* The NT structures NtCreateFile and NtSetInformationFile take, as winternl.h declares them; declared here because
   HashLink's headers define names winternl.h uses. */
typedef struct {
	USHORT Length;
	USHORT MaximumLength;
	PWSTR Buffer;
} realtime_fs_unicode_string;

typedef struct {
	ULONG Length;
	HANDLE RootDirectory;
	realtime_fs_unicode_string *ObjectName;
	ULONG Attributes;
	PVOID SecurityDescriptor;
	PVOID SecurityQualityOfService;
} realtime_fs_object_attributes;

typedef struct {
	union {
		LONG Status;
		PVOID Pointer;
	};
	ULONG_PTR Information;
} realtime_fs_io_status;

typedef LONG (NTAPI *realtime_fs_nt_create_file)( PHANDLE, ACCESS_MASK, realtime_fs_object_attributes *,
	realtime_fs_io_status *, PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG );
typedef ULONG (NTAPI *realtime_fs_nt_status_error)( LONG );
typedef LONG (NTAPI *realtime_fs_nt_set_information)( HANDLE, realtime_fs_io_status *, PVOID, ULONG, ULONG );

/* FILE_RENAME_INFORMATION, whose RootDirectory NtSetInformationFile honours. */
typedef struct {
	BOOLEAN ReplaceIfExists;
	HANDLE RootDirectory;
	ULONG FileNameLength;
	WCHAR FileName[1];
} realtime_fs_rename_information;
#define REALTIME_FS_FILE_RENAME_INFORMATION 10

static realtime_fs_nt_create_file realtime_fs_create_file;
static realtime_fs_nt_status_error realtime_fs_status_error;
static realtime_fs_nt_set_information realtime_fs_set_information;

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
	case ERROR_ACCESS_DENIED: case ERROR_WRITE_PROTECT: case ERROR_PRIVILEGE_NOT_HELD: case ERROR_SHARING_VIOLATION:
	case ERROR_LOCK_VIOLATION:
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

/* NtCreateFile, NtSetInformationFile and the status-to-error mapping, from ntdll, which every process has loaded. */
static bool realtime_fs_nt( void ) {
	if( realtime_fs_create_file != NULL ) return true;
	HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
	if( ntdll == NULL ) return realtime_fs_refuse(REALTIME_FS_UNSUPPORTED);
	realtime_fs_status_error = (realtime_fs_nt_status_error)(void *)GetProcAddress(ntdll,"RtlNtStatusToDosError");
	realtime_fs_set_information = (realtime_fs_nt_set_information)(void *)GetProcAddress(ntdll,"NtSetInformationFile");
	realtime_fs_create_file = (realtime_fs_nt_create_file)(void *)GetProcAddress(ntdll,"NtCreateFile");
	if( realtime_fs_create_file == NULL || realtime_fs_status_error == NULL || realtime_fs_set_information == NULL ) {
		realtime_fs_create_file = NULL;
		return realtime_fs_refuse(REALTIME_FS_UNSUPPORTED);
	}
	return true;
}

static wchar_t *realtime_fs_concat( const wchar_t *a, const wchar_t *b, const wchar_t *c ) {
	size_t la = wcslen(a), lb = wcslen(b), lc = wcslen(c);
	wchar_t *result = (wchar_t *)malloc((la + lb + lc + 1) * sizeof(wchar_t));
	if( result == NULL ) return NULL;
	memcpy(result,a,la * sizeof(wchar_t));
	memcpy(result + la,b,lb * sizeof(wchar_t));
	memcpy(result + la + lb,c,lc * sizeof(wchar_t));
	result[la + lb + lc] = 0;
	return result;
}

/* `path` made absolute against the working directory, with `\` separators; NULL after recording why. */
static wchar_t *realtime_fs_full_path( const wchar_t *path ) {
	DWORD needed = GetFullPathNameW(path,0,NULL,NULL);
	if( needed == 0 ) {
		realtime_fs_fail(GetLastError());
		return NULL;
	}
	wchar_t *full = (wchar_t *)malloc(needed * sizeof(wchar_t));
	if( full == NULL ) {
		realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
		return NULL;
	}
	if( GetFullPathNameW(path,needed,full,NULL) == 0 ) {
		realtime_fs_fail(GetLastError());
		free(full);
		return NULL;
	}
	return full;
}

/* An absolute Win32 path as the NT object name NtCreateFile and renames take: `\??\C:\...` or `\??\UNC\server\...`. */
static wchar_t *realtime_fs_nt_name( const wchar_t *full ) {
	if( wcsncmp(full,L"\\\\?\\",4) == 0 || wcsncmp(full,L"\\\\.\\",4) == 0 ) return realtime_fs_concat(L"\\??\\",full + 4,L"");
	if( wcsncmp(full,L"\\\\",2) == 0 ) return realtime_fs_concat(L"\\??\\UNC\\",full + 2,L"");
	return realtime_fs_concat(L"\\??\\",full,L"");
}

/* Windows answers "path not found" where a part of the way to `path` is a file; POSIX answers ENOTDIR, which is what the
   failure is. `path` is a Win32 path, or an NT name (`\??\...`), which `\\?\` names for the Win32 calls. */
static void realtime_fs_classify_missing( const wchar_t *path ) {
	if( realtime_fs_code != ERROR_PATH_NOT_FOUND ) return;
	wchar_t *prefix = wcsncmp(path,L"\\??\\",4) == 0 ? realtime_fs_concat(L"\\\\?\\",path + 4,L"")
		: realtime_fs_concat(path,L"",L"");
	if( prefix == NULL ) return;
	for(;;) {
		wchar_t *cut = NULL;
		for( wchar_t *at = prefix; *at; at++ )
			if( *at == L'\\' || *at == L'/' ) cut = at;
		if( cut == NULL || cut == prefix ) break;
		*cut = 0;
		DWORD attributes = GetFileAttributesW(prefix);
		if( attributes != INVALID_FILE_ATTRIBUTES ) {
			if( (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ) realtime_fs_kind = REALTIME_FS_NOT_A_DIRECTORY;
			break;
		}
	}
	free(prefix);
}

static bool realtime_fs_final_path( HANDLE handle, wchar_t **out ) {
	DWORD capacity = 512;
	for(;;) {
		wchar_t *buffer = (wchar_t *)malloc(capacity * sizeof(wchar_t));
		if( buffer == NULL ) return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
		DWORD count = GetFinalPathNameByHandleW(handle,buffer,capacity,FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
		if( count == 0 ) {
			free(buffer);
			return realtime_fs_fail(GetLastError());
		}
		if( count < capacity ) {
			*out = buffer;
			return true;
		}
		free(buffer);
		capacity = count + 1;
	}
}

/* Whether the final path `path` is `root` or beneath it, compared as the filesystem compares names. */
static bool realtime_fs_within( const wchar_t *path, const wchar_t *root ) {
	int root_length = (int)wcslen(root), length = (int)wcslen(path);
	if( length < root_length || CompareStringOrdinal(path,root_length,root,root_length,TRUE) != CSTR_EQUAL ) return false;
	return length == root_length || root[root_length - 1] == L'\\' || path[root_length] == L'\\';
}

static bool realtime_fs_identity( HANDLE handle, DWORD *volume, DWORD *high, DWORD *low ) {
	BY_HANDLE_FILE_INFORMATION information;
	if( !GetFileInformationByHandle(handle,&information) ) return false;
	*volume = information.dwVolumeSerialNumber;
	*high = information.nFileIndexHigh;
	*low = information.nFileIndexLow;
	return true;
}

/* Whether the root's path still names its directory, not one put in its place. */
static bool realtime_fs_root_holds( const realtime_fs_directory *root ) {
	HANDLE current = CreateFileW(root->path,FILE_READ_ATTRIBUTES,REALTIME_FS_SHARE_ALL,NULL,OPEN_EXISTING,
		FILE_FLAG_BACKUP_SEMANTICS,NULL);
	if( current == INVALID_HANDLE_VALUE ) return false;
	DWORD volume, high, low;
	bool same = realtime_fs_identity(current,&volume,&high,&low) && volume == root->volume && high == root->index_high
		&& low == root->index_low;
	CloseHandle(current);
	return same;
}

static bool realtime_fs_attributes_of( HANDLE handle, FILE_ATTRIBUTE_TAG_INFO *tag ) {
	if( GetFileInformationByHandleEx(handle,FileAttributeTagInfo,tag,sizeof(*tag)) ) return true;
	return realtime_fs_fail(GetLastError());
}

static bool realtime_fs_is_link( const FILE_ATTRIBUTE_TAG_INFO *tag ) {
	return (tag->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
		&& (tag->ReparseTag == IO_REPARSE_TAG_SYMLINK || tag->ReparseTag == IO_REPARSE_TAG_MOUNT_POINT);
}

static bool realtime_fs_names_directory( const wchar_t *path ) {
	DWORD attributes = GetFileAttributesW(path);
	return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/* Opens what is at `path` with `access` (FILE_FLAG_OPEN_REPARSE_POINT in `flags` opens a link itself), or answers
   INVALID_HANDLE_VALUE after recording why. A root's handle is kept only when its final path is beneath the root. */
static HANDLE realtime_fs_open( realtime_fs_directory *root, const wchar_t *path, DWORD access, DWORD flags ) {
	wchar_t *owned = NULL;
	const wchar_t *target = path;
	if( root != NULL ) {
		if( root->handle == INVALID_HANDLE_VALUE ) {
			realtime_fs_fail(ERROR_INVALID_HANDLE);
			return INVALID_HANDLE_VALUE;
		}
		if( !realtime_fs_confined(path) ) {
			realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
			return INVALID_HANDLE_VALUE;
		}
		if( realtime_fs_is_self(path) ) target = root->path;
		else {
			owned = realtime_fs_concat(root->path,L"\\",path);
			if( owned == NULL ) {
				realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
				return INVALID_HANDLE_VALUE;
			}
			for( wchar_t *at = owned; *at; at++ )
				if( *at == L'/' ) *at = L'\\';
			target = owned;
		}
	}
	HANDLE handle = INVALID_HANDLE_VALUE;
	for( int attempt = 0;; attempt++ ) {
		handle = CreateFileW(target,access,REALTIME_FS_SHARE_ALL,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS | flags,NULL);
		if( handle != INVALID_HANDLE_VALUE ) break;
		DWORD error = GetLastError();
		/* A process that holds the file without sharing it (a scanner, an indexer) lets go within a moment, and a file an
		   atomic write is replacing refuses opens while the replaced one is pending deletion. */
		bool transient = error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION || error == ERROR_DELETE_PENDING
			|| (error == ERROR_ACCESS_DENIED && !realtime_fs_names_directory(target));
		if( !transient || attempt == 20 ) {
			realtime_fs_fail(error);
			realtime_fs_classify_missing(target);
			free(owned);
			return INVALID_HANDLE_VALUE;
		}
		Sleep(attempt < 5 ? 10 : 50);
	}
	free(owned);
	if( root != NULL ) {
		wchar_t *resolved = NULL;
		bool inside = realtime_fs_final_path(handle,&resolved) && realtime_fs_within(resolved,root->path)
			&& realtime_fs_root_holds(root);
		free(resolved);
		if( !inside ) {
			CloseHandle(handle);
			realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
			return INVALID_HANDLE_VALUE;
		}
	}
	return handle;
}

/* Where an operation that names its target acts: a directory handle and a name in it, or (no handle) an NT path. */
typedef struct {
	HANDLE directory;
	wchar_t *name;
} realtime_fs_place;

/* `path` as a place, or false after recording why; the root itself (".") fails with `self_error`. */
static bool realtime_fs_place_of( realtime_fs_directory *root, const wchar_t *path, realtime_fs_place *place,
	DWORD self_error ) {
	place->directory = NULL;
	place->name = NULL;
	if( !realtime_fs_nt() ) return false;
	if( root == NULL ) {
		wchar_t *full = realtime_fs_full_path(path);
		if( full == NULL ) return false;
		place->name = realtime_fs_nt_name(full);
		free(full);
		return place->name != NULL || realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	}
	if( !realtime_fs_confined(path) ) return realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
	if( realtime_fs_is_self(path) ) return realtime_fs_fail(self_error);
	const wchar_t *slash = wcsrchr(path,L'/');
	const wchar_t *name = slash == NULL ? path : slash + 1;
	HANDLE directory;
	if( slash == NULL ) directory = realtime_fs_open(root,L".",FILE_LIST_DIRECTORY | FILE_TRAVERSE | SYNCHRONIZE,0);
	else {
		size_t length = (size_t)(slash - path);
		wchar_t *parent = (wchar_t *)malloc((length + 1) * sizeof(wchar_t));
		if( parent == NULL ) return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
		memcpy(parent,path,length * sizeof(wchar_t));
		parent[length] = 0;
		directory = realtime_fs_open(root,parent,FILE_LIST_DIRECTORY | FILE_TRAVERSE | SYNCHRONIZE,0);
		free(parent);
	}
	if( directory == INVALID_HANDLE_VALUE ) return false;
	/* CreateFileW opens a file as readily as a directory; names are looked up only in a directory. */
	FILE_ATTRIBUTE_TAG_INFO tag;
	bool described = realtime_fs_attributes_of(directory,&tag);
	if( !described || (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ) {
		CloseHandle(directory);
		return described ? realtime_fs_fail(ERROR_DIRECTORY) : false;
	}
	place->directory = directory;
	place->name = realtime_fs_concat(name,L"",L"");
	if( place->name == NULL ) {
		CloseHandle(directory);
		place->directory = NULL;
		return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	}
	return true;
}

static void realtime_fs_place_release( realtime_fs_place *place ) {
	if( place->directory != NULL ) CloseHandle(place->directory);
	free(place->name);
	place->directory = NULL;
	place->name = NULL;
}

/* Opens `name` in the place's directory (or the place's own name, when `name` is NULL). */
static bool realtime_fs_open_at( const realtime_fs_place *place, const wchar_t *name, ACCESS_MASK access,
	ULONG disposition, ULONG options, HANDLE *out ) {
	const wchar_t *object = name == NULL ? place->name : name;
	realtime_fs_unicode_string text;
	text.Buffer = (PWSTR)object;
	text.Length = (USHORT)(wcslen(object) * sizeof(wchar_t));
	text.MaximumLength = text.Length;
	realtime_fs_object_attributes attributes;
	memset(&attributes,0,sizeof(attributes));
	attributes.Length = sizeof(attributes);
	attributes.RootDirectory = place->directory;
	attributes.ObjectName = &text;
	attributes.Attributes = OBJ_CASE_INSENSITIVE;
	realtime_fs_io_status status;
	LONG result = realtime_fs_create_file(out,access | SYNCHRONIZE,&attributes,&status,NULL,FILE_ATTRIBUTE_NORMAL,
		REALTIME_FS_SHARE_ALL,disposition,options | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_FOR_BACKUP_INTENT,NULL,0);
	if( result < 0 ) {
		*out = INVALID_HANDLE_VALUE;
		realtime_fs_fail(realtime_fs_status_error(result));
		if( place->directory == NULL ) realtime_fs_classify_missing(object);
		return false;
	}
	return true;
}

/* Moves the open `handle` to the place's name, replacing a file there when `replace`. */
static bool realtime_fs_rename_handle( HANDLE handle, const realtime_fs_place *place, bool replace ) {
	size_t length = wcslen(place->name);
	size_t size = sizeof(realtime_fs_rename_information) + length * sizeof(wchar_t);
	realtime_fs_rename_information *information = (realtime_fs_rename_information *)calloc(1,size);
	if( information == NULL ) return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	information->ReplaceIfExists = replace;
	information->RootDirectory = place->directory;
	information->FileNameLength = (ULONG)(length * sizeof(wchar_t));
	memcpy(information->FileName,place->name,length * sizeof(wchar_t));
	DWORD error = ERROR_SUCCESS;
	/* A process that has the target open without FILE_SHARE_DELETE refuses the rename for a moment. */
	for( int attempt = 0;; attempt++ ) {
		realtime_fs_io_status status;
		LONG result = realtime_fs_set_information(handle,&status,information,(ULONG)size,REALTIME_FS_FILE_RENAME_INFORMATION);
		error = result >= 0 ? ERROR_SUCCESS : realtime_fs_status_error(result);
		if( error == ERROR_SUCCESS || (error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION
			&& error != ERROR_LOCK_VIOLATION) || attempt == 20 )
			break;
		Sleep(attempt < 5 ? 10 : 50);
	}
	free(information);
	return error == ERROR_SUCCESS || realtime_fs_fail(error);
}

static bool realtime_fs_dispose( HANDLE handle ) {
	FILE_DISPOSITION_INFO disposition;
	disposition.DeleteFile = TRUE;
	return SetFileInformationByHandle(handle,FileDispositionInfo,&disposition,sizeof(disposition))
		|| realtime_fs_fail(GetLastError());
}

static bool realtime_fs_read_handle( HANDLE handle, unsigned char **data, int *length ) {
	FILE_ATTRIBUTE_TAG_INFO tag;
	LARGE_INTEGER size;
	if( !realtime_fs_attributes_of(handle,&tag) ) {
		CloseHandle(handle);
		return false;
	}
	if( tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY ) {
		CloseHandle(handle);
		return realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
	}
	if( !GetFileSizeEx(handle,&size) ) {
		DWORD error = GetLastError();
		CloseHandle(handle);
		return realtime_fs_fail(error);
	}
	if( size.QuadPart > 0x7FFFFFFF ) {
		CloseHandle(handle);
		return realtime_fs_fail(ERROR_FILE_TOO_LARGE);
	}
	/* One byte past the end stays free, for a caller that ends the data with a NUL. */
	int capacity = (int)size.QuadPart, used = 0;
	unsigned char *buffer = (unsigned char *)malloc((size_t)capacity + 1);
	if( buffer == NULL ) {
		CloseHandle(handle);
		return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	}
	while( used < capacity ) {
		DWORD got = 0;
		if( !ReadFile(handle,buffer + used,(DWORD)(capacity - used),&got,NULL) ) {
			DWORD error = GetLastError();
			free(buffer);
			CloseHandle(handle);
			return realtime_fs_fail(error);
		}
		if( got == 0 ) break;
		used += (int)got;
	}
	CloseHandle(handle);
	*data = buffer;
	*length = used;
	return realtime_fs_succeed();
}

static bool realtime_fs_write_handle( HANDLE handle, const unsigned char *data, int length ) {
	int offset = 0;
	while( offset < length ) {
		DWORD written = 0;
		if( !WriteFile(handle,data + offset,(DWORD)(length - offset),&written,NULL) || written == 0 ) {
			DWORD error = GetLastError();
			return realtime_fs_fail(error == ERROR_SUCCESS ? ERROR_WRITE_FAULT : error);
		}
		offset += (int)written;
	}
	return true;
}

/* The whole file, in a buffer the caller frees, with one byte free past its end. */
static bool realtime_fs_read( realtime_fs_directory *root, const wchar_t *path, unsigned char **data, int *length ) {
	HANDLE handle = realtime_fs_open(root,path,GENERIC_READ,0);
	return handle != INVALID_HANDLE_VALUE && realtime_fs_read_handle(handle,data,length);
}

/* Opens the file `path` to write it as `mode` says (replacing what it holds, appending, or only creating it), with
   `extra` access beside writing (GENERIC_READ for a stream that reads too); INVALID_HANDLE_VALUE after recording why. A
   link is written through, to what it points to, which for a root must be beneath it too. */
static HANDLE realtime_fs_open_written( realtime_fs_directory *root, const wchar_t *path, int mode, ACCESS_MASK extra ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,ERROR_ACCESS_DENIED) ) {
		if( realtime_fs_is_self(path) ) realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
		return INVALID_HANDLE_VALUE;
	}
	ACCESS_MASK access = (mode == REALTIME_FS_APPEND ? FILE_APPEND_DATA : GENERIC_WRITE) | FILE_READ_ATTRIBUTES | extra;
	HANDLE handle = INVALID_HANDLE_VALUE;
	bool opened = false;
	for( int attempt = 0; attempt < 4 && !opened; attempt++ ) {
		HANDLE probe;
		if( !realtime_fs_open_at(&place,NULL,FILE_READ_ATTRIBUTES,FILE_OPEN,FILE_OPEN_REPARSE_POINT,&probe) ) {
			if( realtime_fs_kind != REALTIME_FS_NOT_FOUND ) break;
			/* Nothing there: create it; another process may make it meanwhile, so look again. */
			opened = realtime_fs_open_at(&place,NULL,access,FILE_CREATE,FILE_NON_DIRECTORY_FILE,&handle);
			if( !opened && realtime_fs_kind != REALTIME_FS_ALREADY_EXISTS ) break;
			if( !opened && mode == REALTIME_FS_CREATE ) break;
			continue;
		}
		FILE_ATTRIBUTE_TAG_INFO tag;
		bool described = realtime_fs_attributes_of(probe,&tag);
		CloseHandle(probe);
		if( !described ) break;
		if( mode == REALTIME_FS_CREATE ) {
			realtime_fs_fail(ERROR_FILE_EXISTS);
			break;
		}
		if( realtime_fs_is_link(&tag) ) {
			/* A link is written through, to what it points to, which for a root must be beneath it too. */
			handle = realtime_fs_open(root,path,access,0);
			if( handle == INVALID_HANDLE_VALUE ) break;
			FILE_ATTRIBUTE_TAG_INFO target;
			if( !realtime_fs_attributes_of(handle,&target) ) break;
			if( target.FileAttributes & FILE_ATTRIBUTE_DIRECTORY ) {
				realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
				break;
			}
			FILE_END_OF_FILE_INFO end;
			end.EndOfFile.QuadPart = 0;
			opened = mode != REALTIME_FS_REPLACE
				|| SetFileInformationByHandle(handle,FileEndOfFileInfo,&end,sizeof(end))
				|| realtime_fs_fail(GetLastError());
			break;
		}
		if( tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY ) {
			realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
			break;
		}
		opened = realtime_fs_open_at(&place,NULL,access,mode == REALTIME_FS_REPLACE ? FILE_OVERWRITE : FILE_OPEN,
			FILE_NON_DIRECTORY_FILE,&handle);
		if( !opened && realtime_fs_kind != REALTIME_FS_NOT_FOUND ) break;
	}
	realtime_fs_place_release(&place);
	if( !opened ) {
		if( handle != INVALID_HANDLE_VALUE ) CloseHandle(handle);
		return INVALID_HANDLE_VALUE;
	}
	return handle;
}

static bool realtime_fs_write( realtime_fs_directory *root, const wchar_t *path, const unsigned char *data, int length,
	int mode ) {
	HANDLE handle = realtime_fs_open_written(root,path,mode,0);
	if( handle == INVALID_HANDLE_VALUE ) return false;
	bool written = realtime_fs_write_handle(handle,data,length);
	if( !CloseHandle(handle) && written ) return realtime_fs_fail(GetLastError());
	return written && realtime_fs_succeed();
}

static bool realtime_fs_write_atomic( realtime_fs_directory *root, const wchar_t *path, const unsigned char *data,
	int length, bool replace ) {
	static volatile LONG sequence = 0;
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,ERROR_ACCESS_DENIED) ) {
		if( realtime_fs_is_self(path) ) realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
		return false;
	}
	HANDLE probe;
	if( realtime_fs_open_at(&place,NULL,FILE_READ_ATTRIBUTES,FILE_OPEN,FILE_OPEN_REPARSE_POINT,&probe) ) {
		FILE_ATTRIBUTE_TAG_INFO tag;
		bool described = realtime_fs_attributes_of(probe,&tag);
		CloseHandle(probe);
		if( !described ) {
			realtime_fs_place_release(&place);
			return false;
		}
		if( (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !realtime_fs_is_link(&tag) ) {
			realtime_fs_place_release(&place);
			return realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
		}
	} else if( realtime_fs_kind != REALTIME_FS_NOT_FOUND ) {
		realtime_fs_place_release(&place);
		return false;
	}
	size_t name_length = wcslen(place.name);
	wchar_t *temporary = (wchar_t *)malloc((name_length + 64) * sizeof(wchar_t));
	if( temporary == NULL ) {
		realtime_fs_place_release(&place);
		return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	}
	HANDLE handle = INVALID_HANDLE_VALUE;
	bool created = false;
	for( int attempt = 0; attempt < 128 && !created; attempt++ ) {
		_snwprintf(temporary,name_length + 64,L"%ls.%lu.%ld.tmp",place.name,(unsigned long)GetCurrentProcessId(),
			(long)InterlockedIncrement(&sequence));
		created = realtime_fs_open_at(&place,temporary,GENERIC_WRITE | DELETE,FILE_CREATE,FILE_NON_DIRECTORY_FILE,&handle);
		if( !created && realtime_fs_kind != REALTIME_FS_ALREADY_EXISTS ) break;
	}
	free(temporary);
	bool done = created && realtime_fs_write_handle(handle,data,length)
		&& (FlushFileBuffers(handle) || realtime_fs_fail(GetLastError()))
		&& realtime_fs_rename_handle(handle,&place,replace);
	if( created && !done ) {
		int kind = realtime_fs_kind, code = realtime_fs_code;
		realtime_fs_dispose(handle);
		realtime_fs_kind = kind;
		realtime_fs_code = code;
	}
	if( handle != INVALID_HANDLE_VALUE ) CloseHandle(handle);
	realtime_fs_place_release(&place);
	return done && realtime_fs_succeed();
}

static double realtime_fs_unix_seconds( LARGE_INTEGER time ) {
	/* FILETIME counts 100 ns from 1601; Unix seconds count from 1970. */
	return (double)(time.QuadPart - 116444736000000000LL) / 1e7;
}

static bool realtime_fs_metadata_of( realtime_fs_directory *root, const wchar_t *path, bool follow,
	realtime_fs_metadata *out ) {
	HANDLE handle = realtime_fs_open(root,path,FILE_READ_ATTRIBUTES,follow ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
	if( handle == INVALID_HANDLE_VALUE ) return false;
	FILE_BASIC_INFO basic;
	FILE_STANDARD_INFO standard;
	FILE_ATTRIBUTE_TAG_INFO tag;
	if( !GetFileInformationByHandleEx(handle,FileBasicInfo,&basic,sizeof(basic))
		|| !GetFileInformationByHandleEx(handle,FileStandardInfo,&standard,sizeof(standard))
		|| !GetFileInformationByHandleEx(handle,FileAttributeTagInfo,&tag,sizeof(tag)) ) {
		DWORD error = GetLastError();
		CloseHandle(handle);
		return realtime_fs_fail(error);
	}
	CloseHandle(handle);
	out->kind = !follow && realtime_fs_is_link(&tag) ? REALTIME_FS_LINK
		: standard.Directory ? REALTIME_FS_DIRECTORY
		: (tag.FileAttributes & FILE_ATTRIBUTE_DEVICE) ? REALTIME_FS_OTHER : REALTIME_FS_FILE;
	out->size = out->kind == REALTIME_FS_FILE ? (int64_t)standard.EndOfFile.QuadPart : 0;
	out->modified = realtime_fs_unix_seconds(basic.LastWriteTime);
	return realtime_fs_succeed();
}

static bool realtime_fs_list( realtime_fs_directory *root, const wchar_t *path, realtime_fs_emit emit, void *context ) {
	HANDLE handle = realtime_fs_open(root,path,FILE_LIST_DIRECTORY | SYNCHRONIZE,0);
	if( handle == INVALID_HANDLE_VALUE ) return false;
	FILE_ATTRIBUTE_TAG_INFO tag;
	if( !realtime_fs_attributes_of(handle,&tag) ) {
		CloseHandle(handle);
		return false;
	}
	if( !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ) {
		CloseHandle(handle);
		return realtime_fs_fail(ERROR_DIRECTORY);
	}
	enum { capacity = 64 * 1024 };
	unsigned char *buffer = (unsigned char *)malloc(capacity);
	if( buffer == NULL ) {
		CloseHandle(handle);
		return realtime_fs_fail(ERROR_NOT_ENOUGH_MEMORY);
	}
	bool first = true;
	for(;;) {
		if( !GetFileInformationByHandleEx(handle,first ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo,buffer,
			capacity) ) {
			DWORD error = GetLastError();
			free(buffer);
			CloseHandle(handle);
			return error == ERROR_NO_MORE_FILES ? realtime_fs_succeed() : realtime_fs_fail(error);
		}
		first = false;
		FILE_ID_BOTH_DIR_INFO *item = (FILE_ID_BOTH_DIR_INFO *)buffer;
		for(;;) {
			int name_length = (int)(item->FileNameLength / sizeof(wchar_t));
			bool dots = item->FileName[0] == L'.' && (name_length == 1 || (name_length == 2 && item->FileName[1] == L'.'));
			if( !dots ) {
				/* A reparse point's tag is where the extended attributes' size would be. */
				bool link = (item->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
					&& (item->EaSize == IO_REPARSE_TAG_SYMLINK || item->EaSize == IO_REPARSE_TAG_MOUNT_POINT);
				int kind = link ? REALTIME_FS_LINK : (item->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? REALTIME_FS_DIRECTORY
					: (item->FileAttributes & FILE_ATTRIBUTE_DEVICE) ? REALTIME_FS_OTHER : REALTIME_FS_FILE;
				emit(context,item->FileName,name_length,kind);
			}
			if( item->NextEntryOffset == 0 ) break;
			item = (FILE_ID_BOTH_DIR_INFO *)((unsigned char *)item + item->NextEntryOffset);
		}
	}
}

static bool realtime_fs_create_directory( realtime_fs_directory *root, const wchar_t *path ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,ERROR_ALREADY_EXISTS) ) return false;
	HANDLE handle;
	bool created = realtime_fs_open_at(&place,NULL,FILE_LIST_DIRECTORY,FILE_CREATE,FILE_DIRECTORY_FILE,&handle);
	if( created ) CloseHandle(handle);
	realtime_fs_place_release(&place);
	return created && realtime_fs_succeed();
}

/* Deletes what the place names: a file or link when `directory` is false, an empty directory when it is true. */
static bool realtime_fs_delete( realtime_fs_directory *root, const wchar_t *path, bool directory ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,ERROR_ACCESS_DENIED) ) return false;
	HANDLE handle;
	bool opened = realtime_fs_open_at(&place,NULL,DELETE | FILE_READ_ATTRIBUTES,FILE_OPEN,FILE_OPEN_REPARSE_POINT,&handle);
	realtime_fs_place_release(&place);
	if( !opened ) return false;
	FILE_ATTRIBUTE_TAG_INFO tag;
	bool deleted = realtime_fs_attributes_of(handle,&tag);
	if( deleted ) {
		bool is_directory = (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 && !realtime_fs_is_link(&tag);
		if( !directory && is_directory ) deleted = realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
		else if( directory && !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ) deleted = realtime_fs_fail(ERROR_DIRECTORY);
		else deleted = realtime_fs_dispose(handle);
	}
	CloseHandle(handle);
	return deleted && realtime_fs_succeed();
}

static bool realtime_fs_delete_file( realtime_fs_directory *root, const wchar_t *path ) {
	return realtime_fs_delete(root,path,false);
}

static bool realtime_fs_delete_directory( realtime_fs_directory *root, const wchar_t *path ) {
	return realtime_fs_delete(root,path,true);
}

static bool realtime_fs_rename( realtime_fs_directory *root, const wchar_t *path, const wchar_t *target ) {
	realtime_fs_place from, to;
	if( !realtime_fs_place_of(root,path,&from,ERROR_ACCESS_DENIED) ) return false;
	if( !realtime_fs_place_of(root,target,&to,ERROR_ACCESS_DENIED) ) {
		realtime_fs_place_release(&from);
		return false;
	}
	HANDLE handle;
	bool moved = realtime_fs_open_at(&from,NULL,DELETE | FILE_READ_ATTRIBUTES,FILE_OPEN,FILE_OPEN_REPARSE_POINT,&handle);
	if( moved ) {
		moved = realtime_fs_rename_handle(handle,&to,true);
		CloseHandle(handle);
	}
	realtime_fs_place_release(&from);
	realtime_fs_place_release(&to);
	return moved && realtime_fs_succeed();
}

static bool realtime_fs_root_open( realtime_fs_directory *out, const wchar_t *path ) {
	out->handle = INVALID_HANDLE_VALUE;
	out->path = NULL;
	if( !realtime_fs_nt() ) return false;
	wchar_t *full = realtime_fs_full_path(path);
	if( full == NULL ) return false;
	HANDLE handle = CreateFileW(full,FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_TRAVERSE | SYNCHRONIZE,
		REALTIME_FS_SHARE_ALL,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
	free(full);
	if( handle == INVALID_HANDLE_VALUE ) return realtime_fs_fail(GetLastError());
	FILE_ATTRIBUTE_TAG_INFO tag;
	if( !realtime_fs_attributes_of(handle,&tag) ) {
		CloseHandle(handle);
		return false;
	}
	if( !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ) {
		CloseHandle(handle);
		return realtime_fs_fail(ERROR_DIRECTORY);
	}
	if( !realtime_fs_identity(handle,&out->volume,&out->index_high,&out->index_low) ) {
		DWORD error = GetLastError();
		CloseHandle(handle);
		return realtime_fs_fail(error);
	}
	if( !realtime_fs_final_path(handle,&out->path) ) {
		CloseHandle(handle);
		return false;
	}
	out->handle = handle;
	return realtime_fs_succeed();
}

static void realtime_fs_root_close( realtime_fs_directory *root ) {
	if( root->handle != INVALID_HANDLE_VALUE ) CloseHandle(root->handle);
	free(root->path);
	root->handle = INVALID_HANDLE_VALUE;
	root->path = NULL;
}

#else
/* ------------------------------------------------------------------------------------------------ POSIX */

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

#if defined(__APPLE__)
/* Whether a symbolic link is on `path` beneath `directory`, its last part included; no link is followed. */
static bool realtime_fs_link_on_path( int directory, const char *path ) {
	size_t length = strlen(path);
	char *prefix = (char *)malloc(length + 1);
	if( prefix == NULL ) return false;
	memcpy(prefix,path,length + 1);
	bool found = false;
	for( size_t at = 1; at <= length && !found; at++ ) {
		if( prefix[at] != '/' && prefix[at] != 0 ) continue;
		char kept = prefix[at];
		prefix[at] = 0;
		struct stat info;
		found = fstatat(directory,prefix,&info,AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(info.st_mode);
		prefix[at] = kept;
	}
	free(prefix);
	return found;
}
#endif

/* A failure resolving `path` beneath the directory `directory`: the kernel's refusal to leave it is EscapesRoot, its lack
   of the resolution Unsupported. macOS refuses with EACCES, which a permission also answers: the refusal is an escape when
   a symbolic link is on the path, since one that stayed beneath would have been followed. */
static bool realtime_fs_fail_beneath( int error, int directory, const char *path ) {
#if defined(REALTIME_FS_OPENAT2)
	(void)directory; (void)path;
	if( error == EXDEV ) return realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
	if( error == ENOSYS || error == E2BIG ) return realtime_fs_refuse(REALTIME_FS_UNSUPPORTED);
#elif defined(__APPLE__)
	if( error == ENOTCAPABLE ) return realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
	if( error == EACCES && realtime_fs_link_on_path(directory,path) ) return realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
#else
	(void)directory; (void)path;
#endif
	return realtime_fs_fail(error);
}

/* Opens `path` beneath the directory `directory`: a symbolic link is followed only while it stays beneath it. */
static int realtime_fs_open_beneath( int directory, const char *path, int flags, int mode ) {
#if defined(REALTIME_FS_OPENAT2)
	struct open_how how;
	memset(&how,0,sizeof(how));
	how.flags = (uint64_t)(unsigned)flags;
	how.mode = (flags & O_CREAT) ? (uint64_t)mode : 0;
	how.resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS;
	return (int)syscall(SYS_openat2,directory,path,&how,sizeof(how));
#elif defined(__APPLE__) && defined(O_RESOLVE_BENEATH)
	return openat(directory,path,flags | O_RESOLVE_BENEATH,mode);
#else
	(void)directory; (void)path; (void)flags; (void)mode;
	errno = ENOSYS;
	return -1;
#endif
}

/* Opens what is at `path` with `flags`, or answers -1 after recording why. */
static int realtime_fs_open( realtime_fs_directory *root, const char *path, int flags, int mode ) {
	if( root == NULL ) {
		int fd = open(path,flags,mode);
		if( fd < 0 ) realtime_fs_fail(errno);
		return fd;
	}
	if( root->fd < 0 ) {
		realtime_fs_fail(EBADF);
		return -1;
	}
	if( !realtime_fs_confined(path) ) {
		realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
		return -1;
	}
	int fd = realtime_fs_open_beneath(root->fd,path,flags,mode);
	if( fd < 0 ) realtime_fs_fail_beneath(errno,root->fd,path);
	return fd;
}

/* Where an operation that names its target acts: a directory descriptor and a name in it. The process's own view is
   the working directory and the whole path. */
typedef struct {
	int directory;
	const char *name;
	bool owned;
} realtime_fs_place;

/* `path` as a place, or false after recording why; the root itself (".") fails with `self_error`. */
static bool realtime_fs_place_of( realtime_fs_directory *root, const char *path, realtime_fs_place *place,
	int self_error ) {
	place->owned = false;
	if( root == NULL ) {
		place->directory = AT_FDCWD;
		place->name = path;
		return true;
	}
	if( root->fd < 0 ) return realtime_fs_fail(EBADF);
	if( !realtime_fs_confined(path) ) return realtime_fs_refuse(REALTIME_FS_ESCAPES_ROOT);
	if( realtime_fs_is_self(path) ) return realtime_fs_fail(self_error);
	const char *slash = strrchr(path,'/');
	if( slash == NULL ) {
		place->directory = root->fd;
		place->name = path;
		return true;
	}
	size_t length = (size_t)(slash - path);
	char *parent = (char *)malloc(length + 1);
	if( parent == NULL ) return realtime_fs_fail(ENOMEM);
	memcpy(parent,path,length);
	parent[length] = 0;
	int fd = realtime_fs_open_beneath(root->fd,parent,O_RDONLY | O_DIRECTORY | O_CLOEXEC,0);
	if( fd < 0 ) {
		bool failed = realtime_fs_fail_beneath(errno,root->fd,parent);
		free(parent);
		return failed;
	}
	free(parent);
	place->directory = fd;
	place->name = slash + 1;
	place->owned = true;
	return true;
}

static void realtime_fs_place_release( realtime_fs_place *place ) {
	if( place->owned ) close(place->directory);
	place->owned = false;
}

/* Makes the place's directory entries durable, after a rename into it. */
static int realtime_fs_sync_directory( const realtime_fs_place *place ) {
	if( place->directory != AT_FDCWD ) return fsync(place->directory) == 0 ? 0 : errno;
	char *parent = strdup(place->name);
	if( parent == NULL ) return ENOMEM;
	char *slash = strrchr(parent,'/');
	if( slash == NULL ) strcpy(parent,".");
	else if( slash == parent ) slash[1] = 0;
	else *slash = 0;
	int fd = open(parent,O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	free(parent);
	if( fd < 0 ) return errno;
	int result = fsync(fd) == 0 ? 0 : errno;
	close(fd);
	return result;
}

static bool realtime_fs_read_descriptor( int fd, unsigned char **data, int *length ) {
	struct stat info;
	if( fstat(fd,&info) != 0 ) {
		int error = errno;
		close(fd);
		return realtime_fs_fail(error);
	}
	if( S_ISDIR(info.st_mode) ) {
		close(fd);
		return realtime_fs_fail(EISDIR);
	}
	/* The measured size is only a first capacity: /proc files and pipes report 0, so read to the end. One byte past the
	   end stays free, for a caller that ends the data with a NUL. */
	size_t capacity = info.st_size > 0 ? (size_t)info.st_size + 1 : 4096, used = 0;
	unsigned char *buffer = (unsigned char *)malloc(capacity);
	if( buffer == NULL ) {
		close(fd);
		return realtime_fs_fail(ENOMEM);
	}
	for(;;) {
		if( used + 1 >= capacity ) {
			if( capacity >= 0x40000000 ) {
				free(buffer);
				close(fd);
				return realtime_fs_fail(EFBIG);
			}
			unsigned char *grown = (unsigned char *)realloc(buffer,capacity * 2);
			if( grown == NULL ) {
				free(buffer);
				close(fd);
				return realtime_fs_fail(ENOMEM);
			}
			buffer = grown;
			capacity *= 2;
		}
		ssize_t got = read(fd,buffer + used,capacity - used);
		if( got < 0 && errno == EINTR ) continue;
		if( got < 0 ) {
			int error = errno;
			free(buffer);
			close(fd);
			return realtime_fs_fail(error);
		}
		if( got == 0 ) break;
		used += (size_t)got;
	}
	close(fd);
	if( used > 0x7FFFFFFF ) {
		free(buffer);
		return realtime_fs_fail(EFBIG);
	}
	*data = buffer;
	*length = (int)used;
	return realtime_fs_succeed();
}

static int realtime_fs_write_descriptor( int fd, const unsigned char *data, int length ) {
	int offset = 0;
	while( offset < length ) {
		ssize_t written = write(fd,data + offset,(size_t)(length - offset));
		if( written < 0 && errno == EINTR ) continue;
		if( written <= 0 ) return written < 0 ? errno : EIO;
		offset += (int)written;
	}
	return 0;
}

/* The whole file, in a buffer the caller frees, with one byte free past its end. */
static bool realtime_fs_read( realtime_fs_directory *root, const char *path, unsigned char **data, int *length ) {
	int fd = realtime_fs_open(root,path,O_RDONLY | O_CLOEXEC | O_NOCTTY,0);
	return fd >= 0 && realtime_fs_read_descriptor(fd,data,length);
}

static bool realtime_fs_write( realtime_fs_directory *root, const char *path, const unsigned char *data, int length,
	int mode ) {
	int flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOCTTY
		| (mode == REALTIME_FS_REPLACE ? O_TRUNC : mode == REALTIME_FS_APPEND ? O_APPEND : O_EXCL);
	int fd = realtime_fs_open(root,path,flags,0666);
	if( fd < 0 ) return false;
	int error = realtime_fs_write_descriptor(fd,data,length);
	if( close(fd) != 0 && error == 0 ) error = errno;
	return error == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
}

static bool realtime_fs_write_atomic( realtime_fs_directory *root, const char *path, const unsigned char *data,
	int length, bool replace ) {
	static unsigned sequence = 0;
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,EISDIR) ) return false;
	struct stat info;
	int status = fstatat(place.directory,place.name,&info,AT_SYMLINK_NOFOLLOW), error = 0;
	if( status != 0 && errno != ENOENT ) error = errno;
	else if( status == 0 && S_ISDIR(info.st_mode) ) error = EISDIR;
	size_t name_length = strlen(place.name);
	char *temporary = (char *)malloc(name_length + 48);
	if( temporary == NULL && error == 0 ) error = ENOMEM;
	int fd = -1;
	for( int attempt = 0; error == 0 && fd < 0 && attempt < 128; attempt++ ) {
		snprintf(temporary,name_length + 48,"%s.%ld.%u.tmp",place.name,(long)getpid(),
			__atomic_add_fetch(&sequence,1,__ATOMIC_RELAXED));
		fd = openat(place.directory,temporary,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0666);
		if( fd < 0 && errno != EEXIST ) error = errno;
	}
	if( error == 0 && fd < 0 ) error = EEXIST;
	if( error == 0 && status == 0 && S_ISREG(info.st_mode) && fchmod(fd,info.st_mode & 07777) != 0 ) error = errno;
	if( error == 0 ) error = realtime_fs_write_descriptor(fd,data,length);
	if( error == 0 && fsync(fd) != 0 ) error = errno;
	if( fd >= 0 && close(fd) != 0 && error == 0 ) error = errno;
	/* Without `replace`, a link fails where something is already there, which a rename would replace. */
	if( error == 0 && replace && renameat(place.directory,temporary,place.directory,place.name) != 0 ) error = errno;
	if( error == 0 && !replace && linkat(place.directory,temporary,place.directory,place.name,0) != 0 ) error = errno;
	if( !replace && fd >= 0 ) unlinkat(place.directory,temporary,0);
	if( error == 0 ) error = realtime_fs_sync_directory(&place);
	else if( replace && fd >= 0 ) unlinkat(place.directory,temporary,0);
	free(temporary);
	realtime_fs_place_release(&place);
	return error == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
}

static int realtime_fs_kind_of_mode( mode_t mode ) {
	return S_ISREG(mode) ? REALTIME_FS_FILE : S_ISDIR(mode) ? REALTIME_FS_DIRECTORY : S_ISLNK(mode) ? REALTIME_FS_LINK
		: REALTIME_FS_OTHER;
}

static bool realtime_fs_metadata_of( realtime_fs_directory *root, const char *path, bool follow,
	realtime_fs_metadata *out ) {
	struct stat info;
	if( root == NULL ) {
		if( (follow ? stat(path,&info) : lstat(path,&info)) != 0 ) return realtime_fs_fail(errno);
	} else if( realtime_fs_is_self(path) ) {
		if( root->fd < 0 ) return realtime_fs_fail(EBADF);
		if( fstat(root->fd,&info) != 0 ) return realtime_fs_fail(errno);
	} else {
		realtime_fs_place place;
		if( !realtime_fs_place_of(root,path,&place,EACCES) ) return false;
		int status = fstatat(place.directory,place.name,&info,AT_SYMLINK_NOFOLLOW);
		int error = errno;
		realtime_fs_place_release(&place);
		if( status != 0 ) return realtime_fs_fail(error);
		if( follow && S_ISLNK(info.st_mode) ) {
			/* What the link points to, which must be beneath the root too. */
#ifdef O_PATH
			int fd = realtime_fs_open(root,path,O_PATH | O_CLOEXEC,0);
#else
			int fd = realtime_fs_open(root,path,O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY,0);
#endif
			if( fd < 0 ) return false;
			status = fstat(fd,&info);
			error = errno;
			close(fd);
			if( status != 0 ) return realtime_fs_fail(error);
		}
	}
	out->kind = realtime_fs_kind_of_mode(info.st_mode);
	out->size = (int64_t)info.st_size;
#if defined(__APPLE__)
	out->modified = (double)info.st_mtimespec.tv_sec + (double)info.st_mtimespec.tv_nsec / 1e9;
#else
	out->modified = (double)info.st_mtim.tv_sec + (double)info.st_mtim.tv_nsec / 1e9;
#endif
	return realtime_fs_succeed();
}

static bool realtime_fs_list( realtime_fs_directory *root, const char *path, realtime_fs_emit emit, void *context ) {
	int fd = realtime_fs_open(root,path,O_RDONLY | O_DIRECTORY | O_CLOEXEC,0);
	if( fd < 0 ) return false;
	DIR *directory = fdopendir(fd);
	if( directory == NULL ) {
		int error = errno;
		close(fd);
		return realtime_fs_fail(error);
	}
	for(;;) {
		errno = 0;
		struct dirent *entry = readdir(directory);
		if( entry == NULL ) {
			int error = errno;
			closedir(directory);
			return error == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
		}
		const char *name = entry->d_name;
		if( name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)) ) continue;
		int kind;
#ifdef DT_UNKNOWN
		if( entry->d_type != DT_UNKNOWN )
			kind = entry->d_type == DT_REG ? REALTIME_FS_FILE : entry->d_type == DT_DIR ? REALTIME_FS_DIRECTORY
				: entry->d_type == DT_LNK ? REALTIME_FS_LINK : REALTIME_FS_OTHER;
		else
#endif
		{
			struct stat info;
			if( fstatat(dirfd(directory),name,&info,AT_SYMLINK_NOFOLLOW) != 0 ) continue;
			kind = realtime_fs_kind_of_mode(info.st_mode);
		}
		emit(context,name,(int)strlen(name),kind);
	}
}

static bool realtime_fs_create_directory( realtime_fs_directory *root, const char *path ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,EEXIST) ) return false;
	int status = mkdirat(place.directory,place.name,0777), error = errno;
	realtime_fs_place_release(&place);
	return status == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
}

/* Deletes the file or symbolic link `path`; a link to a directory goes, not the directory. */
static bool realtime_fs_delete_file( realtime_fs_directory *root, const char *path ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,EISDIR) ) return false;
	struct stat info;
	int status = fstatat(place.directory,place.name,&info,AT_SYMLINK_NOFOLLOW), error = errno;
	/* macOS answers EPERM for a directory, where Linux answers EISDIR. */
	if( status == 0 && S_ISDIR(info.st_mode) ) error = EISDIR;
	else if( status == 0 ) {
		status = unlinkat(place.directory,place.name,0);
		error = errno;
	}
	realtime_fs_place_release(&place);
	return status == 0 && error != EISDIR ? realtime_fs_succeed() : realtime_fs_fail(error);
}

static bool realtime_fs_delete_directory( realtime_fs_directory *root, const char *path ) {
	realtime_fs_place place;
	if( !realtime_fs_place_of(root,path,&place,EACCES) ) return false;
	int status = unlinkat(place.directory,place.name,AT_REMOVEDIR), error = errno;
	realtime_fs_place_release(&place);
	/* POSIX lets rmdir answer EEXIST for a directory that is not empty. */
	return status == 0 ? realtime_fs_succeed() : realtime_fs_fail(error == EEXIST ? ENOTEMPTY : error);
}

static bool realtime_fs_rename( realtime_fs_directory *root, const char *path, const char *target ) {
	realtime_fs_place from, to;
	if( !realtime_fs_place_of(root,path,&from,EACCES) ) return false;
	if( !realtime_fs_place_of(root,target,&to,EACCES) ) {
		realtime_fs_place_release(&from);
		return false;
	}
	int status = renameat(from.directory,from.name,to.directory,to.name), error = errno;
	realtime_fs_place_release(&from);
	realtime_fs_place_release(&to);
	return status == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
}

static bool realtime_fs_root_open( realtime_fs_directory *out, const char *path ) {
	out->fd = -1;
	int fd = open(path,O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if( fd < 0 ) return realtime_fs_fail(errno);
#if defined(REALTIME_FS_OPENAT2)
	/* A kernel before 5.6 has no openat2; never fall back to a resolution that can leave the root. */
	int probe = realtime_fs_open_beneath(fd,".",O_RDONLY | O_DIRECTORY | O_CLOEXEC,0);
	if( probe < 0 ) {
		int error = errno;
		close(fd);
		return error == ENOSYS || error == E2BIG || error == EINVAL ? realtime_fs_refuse(REALTIME_FS_UNSUPPORTED)
			: realtime_fs_fail(error);
	}
	close(probe);
#elif defined(__APPLE__) && defined(O_RESOLVE_BENEATH)
	/* An older kernel may ignore the flag it does not know: require it to refuse an escape, with EACCES as macOS 15 does or
	   ENOTCAPABLE. */
	int escaped = openat(fd,"..",O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_RESOLVE_BENEATH);
	int error = errno;
	if( escaped >= 0 ) close(escaped);
	if( escaped >= 0 || (error != ENOTCAPABLE && error != EACCES) ) {
		close(fd);
		return realtime_fs_refuse(REALTIME_FS_UNSUPPORTED);
	}
#else
	close(fd);
	return realtime_fs_refuse(REALTIME_FS_UNSUPPORTED);
#endif
	out->fd = fd;
	return realtime_fs_succeed();
}

static void realtime_fs_root_close( realtime_fs_directory *root ) {
	if( root->fd >= 0 ) close(root->fd);
	root->fd = -1;
}
#endif

/* The system's description of the last failure on this thread, in a buffer the caller frees. */
static realtime_fs_char *realtime_fs_message( void ) {
#ifdef _WIN32
	if( realtime_fs_code == REALTIME_FS_TEXT_NUL ) return realtime_fs_concat(L"the file holds a NUL character, which a String cannot",L"",L"");
	wchar_t *message = NULL;
	DWORD length = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL,(DWORD)realtime_fs_code,0,(wchar_t *)&message,0,NULL);
	if( length == 0 ) return realtime_fs_concat(L"unknown Windows error",L"",L"");
	while( length > 0 && (message[length - 1] == L'\r' || message[length - 1] == L'\n' || message[length - 1] == L'.') )
		length--;
	message[length] = 0;
	wchar_t *result = realtime_fs_concat(message,L"",L"");
	LocalFree(message);
	return result;
#else
	if( realtime_fs_code == REALTIME_FS_TEXT_NUL ) return strdup("the file holds a NUL character, which a String cannot");
	return strdup(strerror(realtime_fs_code));
#endif
}

/* What kind of entry is at `path` (std.fs.EntryKind), or false: `exists` and `isDirectory` without the rest of the
   metadata. */
static bool realtime_fs_kind_at( realtime_fs_directory *root, const realtime_fs_char *path, bool follow, int *kind ) {
#ifdef _WIN32
	if( root == NULL ) {
		DWORD attributes = GetFileAttributesW(path);
		if( attributes == INVALID_FILE_ATTRIBUTES ) return realtime_fs_fail(GetLastError());
		if( (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 ) {
			*kind = (attributes & FILE_ATTRIBUTE_DIRECTORY) ? REALTIME_FS_DIRECTORY
				: (attributes & FILE_ATTRIBUTE_DEVICE) ? REALTIME_FS_OTHER : REALTIME_FS_FILE;
			return realtime_fs_succeed();
		}
	}
#endif
	realtime_fs_metadata metadata;
	if( !realtime_fs_metadata_of(root,path,follow,&metadata) ) return false;
	*kind = metadata.kind;
	return true;
}

/* `path` as an absolute path, in a buffer the caller frees, or NULL after recording why: with its symbolic links
   resolved on POSIX (realpath), resolved against the working directory on Windows (GetFullPathNameW). */
static realtime_fs_char *realtime_fs_absolute( const realtime_fs_char *path ) {
#ifdef _WIN32
	return realtime_fs_full_path(path);
#else
	char *resolved = realpath(path,NULL);
	if( resolved == NULL ) realtime_fs_fail(errno);
	else realtime_fs_succeed();
	return resolved;
#endif
}

/* What `path` names, as one absolute path with every symbolic link on the way resolved, in a buffer the caller frees;
   NULL after recording why, NotFound when nothing is there. Two paths to one entry answer the same. */
static realtime_fs_char *realtime_fs_canonical( const realtime_fs_char *path ) {
#ifdef _WIN32
	HANDLE handle = realtime_fs_open(NULL,path,FILE_READ_ATTRIBUTES,0);
	if( handle == INVALID_HANDLE_VALUE ) return NULL;
	wchar_t *final = NULL;
	bool found = realtime_fs_final_path(handle,&final);
	CloseHandle(handle);
	if( !found ) return NULL;
	/* The final path is in the `\\?\` namespace; the plain spelling is the one everything else takes. */
	if( wcsncmp(final,L"\\\\?\\UNC\\",8) == 0 ) {
		memmove(final + 2,final + 8,(wcslen(final + 8) + 1) * sizeof(wchar_t));
	} else if( wcsncmp(final,L"\\\\?\\",4) == 0 )
		memmove(final,final + 4,(wcslen(final + 4) + 1) * sizeof(wchar_t));
	realtime_fs_succeed();
	return final;
#else
	char *resolved = realpath(path,NULL);
	if( resolved == NULL ) realtime_fs_fail(errno);
	else realtime_fs_succeed();
	return resolved;
#endif
}

/* Haxe's FileStat of `path`, in its order: gid, uid, atime, mtime, ctime, size, dev, ino, nlink, rdev, mode. */
static bool realtime_fs_stat( const realtime_fs_char *path, int values[11] ) {
#ifdef _WIN32
	struct _stat64 info;
	if( _wstat64(path,&info) != 0 ) return realtime_fs_fail(GetLastError());
#else
	struct stat info;
	if( stat(path,&info) != 0 ) return realtime_fs_fail(errno);
#endif
	values[0] = (int)info.st_gid;
	values[1] = (int)info.st_uid;
	values[2] = (int)info.st_atime;
	values[3] = (int)info.st_mtime;
	values[4] = (int)info.st_ctime;
	values[5] = (int)info.st_size;
	values[6] = (int)info.st_dev;
	values[7] = (int)info.st_ino;
	values[8] = (int)info.st_nlink;
	values[9] = (int)info.st_rdev;
	values[10] = (int)info.st_mode;
	return realtime_fs_succeed();
}

/* An open file (std.fs.FileHandle): opened by mode, then read, written and moved through until it is closed. */
enum { REALTIME_FS_STREAM_READ, REALTIME_FS_STREAM_WRITE, REALTIME_FS_STREAM_APPEND, REALTIME_FS_STREAM_READ_WRITE,
	REALTIME_FS_STREAM_CREATE_NEW };

#ifdef _WIN32
typedef struct {
	HANDLE handle;
} realtime_fs_stream;

/* Opens the file `path` as `mode` says into `stream`, or answers false after recording why. */
static bool realtime_fs_stream_open( realtime_fs_directory *root, const wchar_t *path, int mode, realtime_fs_stream *stream ) {
	HANDLE handle;
	if( mode == REALTIME_FS_STREAM_READ || mode == REALTIME_FS_STREAM_READ_WRITE ) {
		handle = realtime_fs_open(root,path,GENERIC_READ | (mode == REALTIME_FS_STREAM_READ_WRITE ? GENERIC_WRITE : 0),0);
		if( handle == INVALID_HANDLE_VALUE ) return false;
		FILE_ATTRIBUTE_TAG_INFO tag;
		if( !realtime_fs_attributes_of(handle,&tag) ) {
			CloseHandle(handle);
			return false;
		}
		if( tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY ) {
			CloseHandle(handle);
			return realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
		}
	} else {
		int written = mode == REALTIME_FS_STREAM_APPEND ? REALTIME_FS_APPEND
			: mode == REALTIME_FS_STREAM_CREATE_NEW ? REALTIME_FS_CREATE : REALTIME_FS_REPLACE;
		handle = realtime_fs_open_written(root,path,written,0);
		if( handle == INVALID_HANDLE_VALUE ) return false;
	}
	stream->handle = handle;
	return realtime_fs_succeed();
}

/* Reads up to `length` bytes into `data`: how many it read, 0 at the end, -1 after recording why. */
static int realtime_fs_stream_read( realtime_fs_stream *stream, unsigned char *data, int length ) {
	DWORD read = 0;
	if( !ReadFile(stream->handle,data,(DWORD)length,&read,NULL) ) {
		DWORD error = GetLastError();
		if( error == ERROR_HANDLE_EOF || error == ERROR_BROKEN_PIPE ) {
			realtime_fs_succeed();
			return 0;
		}
		realtime_fs_fail(error);
		return -1;
	}
	realtime_fs_succeed();
	return (int)read;
}

static bool realtime_fs_stream_write( realtime_fs_stream *stream, const unsigned char *data, int length ) {
	return realtime_fs_write_handle(stream->handle,data,length) && realtime_fs_succeed();
}

/* Moves to `offset` from the start (0), the current position (1) or the end (2), answering the new position. */
static bool realtime_fs_stream_seek( realtime_fs_stream *stream, int64_t offset, int origin, int64_t *position ) {
	LARGE_INTEGER distance, moved;
	distance.QuadPart = offset;
	DWORD method = origin == 0 ? FILE_BEGIN : origin == 1 ? FILE_CURRENT : FILE_END;
	if( !SetFilePointerEx(stream->handle,distance,&moved,method) ) return realtime_fs_fail(GetLastError());
	*position = moved.QuadPart;
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_size( realtime_fs_stream *stream, int64_t *size ) {
	LARGE_INTEGER value;
	if( !GetFileSizeEx(stream->handle,&value) ) return realtime_fs_fail(GetLastError());
	*size = value.QuadPart;
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_set_length( realtime_fs_stream *stream, int64_t length ) {
	FILE_END_OF_FILE_INFO end;
	end.EndOfFile.QuadPart = length;
	if( !SetFileInformationByHandle(stream->handle,FileEndOfFileInfo,&end,sizeof(end)) )
		return realtime_fs_fail(GetLastError());
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_sync( realtime_fs_stream *stream ) {
	if( !FlushFileBuffers(stream->handle) ) return realtime_fs_fail(GetLastError());
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_close( realtime_fs_stream *stream ) {
	HANDLE handle = stream->handle;
	stream->handle = INVALID_HANDLE_VALUE;
	if( handle != INVALID_HANDLE_VALUE && !CloseHandle(handle) ) return realtime_fs_fail(GetLastError());
	return realtime_fs_succeed();
}

#else
typedef struct {
	int fd;
} realtime_fs_stream;

static bool realtime_fs_stream_open( realtime_fs_directory *root, const char *path, int mode, realtime_fs_stream *stream ) {
	int flags = O_CLOEXEC | O_NOCTTY | (mode == REALTIME_FS_STREAM_READ ? O_RDONLY
		: mode == REALTIME_FS_STREAM_READ_WRITE ? O_RDWR
		: mode == REALTIME_FS_STREAM_APPEND ? O_WRONLY | O_CREAT | O_APPEND
		: mode == REALTIME_FS_STREAM_CREATE_NEW ? O_WRONLY | O_CREAT | O_EXCL
		: O_WRONLY | O_CREAT | O_TRUNC);
	int fd = realtime_fs_open(root,path,flags,0666);
	if( fd < 0 ) return false;
	/* A directory opens for reading; as a file it is the wrong kind. */
	struct stat info;
	if( fstat(fd,&info) != 0 ) {
		int error = errno;
		close(fd);
		return realtime_fs_fail(error);
	}
	if( S_ISDIR(info.st_mode) ) {
		close(fd);
		return realtime_fs_refuse(REALTIME_FS_IS_A_DIRECTORY);
	}
	stream->fd = fd;
	return realtime_fs_succeed();
}

static int realtime_fs_stream_read( realtime_fs_stream *stream, unsigned char *data, int length ) {
	for(;;) {
		ssize_t read_bytes = read(stream->fd,data,(size_t)length);
		if( read_bytes >= 0 ) {
			realtime_fs_succeed();
			return (int)read_bytes;
		}
		if( errno != EINTR ) {
			realtime_fs_fail(errno);
			return -1;
		}
	}
}

static bool realtime_fs_stream_write( realtime_fs_stream *stream, const unsigned char *data, int length ) {
	int error = realtime_fs_write_descriptor(stream->fd,data,length);
	return error == 0 ? realtime_fs_succeed() : realtime_fs_fail(error);
}

static bool realtime_fs_stream_seek( realtime_fs_stream *stream, int64_t offset, int origin, int64_t *position ) {
	off_t moved = lseek(stream->fd,(off_t)offset,origin == 0 ? SEEK_SET : origin == 1 ? SEEK_CUR : SEEK_END);
	if( moved < 0 ) return realtime_fs_fail(errno);
	*position = (int64_t)moved;
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_size( realtime_fs_stream *stream, int64_t *size ) {
	struct stat info;
	if( fstat(stream->fd,&info) != 0 ) return realtime_fs_fail(errno);
	*size = (int64_t)info.st_size;
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_set_length( realtime_fs_stream *stream, int64_t length ) {
	if( ftruncate(stream->fd,(off_t)length) != 0 ) return realtime_fs_fail(errno);
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_sync( realtime_fs_stream *stream ) {
	if( fsync(stream->fd) != 0 ) return realtime_fs_fail(errno);
	return realtime_fs_succeed();
}

static bool realtime_fs_stream_close( realtime_fs_stream *stream ) {
	int fd = stream->fd;
	stream->fd = -1;
	if( fd >= 0 && close(fd) != 0 ) return realtime_fs_fail(errno);
	return realtime_fs_succeed();
}
#endif
