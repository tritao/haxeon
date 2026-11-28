/* std.fs's natives (std.fs.FileNatives): fs_system.c's operations for HashLink. Each takes a root first, null for the
   process's own view of the filesystem, and answers its value, or null or false after recording why; std.fs reads the
   reason back (`__fs_error`, its system code and message) on the same thread before anything else runs on it. */

#include "fs_system.c"

/* A root as std.fs.Root holds it: closed when it is disposed of, or when it is collected. */
typedef struct {
	void (*finalize)( void * );
	realtime_fs_directory directory;
	bool open;
} realtime_fs_root;

static void realtime_fs_root_finalize( void *value ) {
	realtime_fs_root *root = (realtime_fs_root *)value;
	if( root->open ) realtime_fs_root_close(&root->directory);
	root->open = false;
}

/* The directory a root resolves in, or NULL for the process's own view. */
static realtime_fs_directory *realtime_fs_resolver( realtime_fs_root *root ) {
	return root == NULL ? NULL : &root->directory;
}

#ifdef HL_WIN
#define REALTIME_FS_PATH( name, value ) const realtime_fs_char *name = (const realtime_fs_char *)realtime_string_data(value)
#define REALTIME_FS_PATH_END( name )
#else
#define REALTIME_FS_PATH( name, value ) char *name = realtime_utf8_copy(value)
#define REALTIME_FS_PATH_END( name ) free(name)
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
	realtime_fs_char *message = realtime_fs_message();
	if( message == NULL ) return realtime_string_from_utf8("unknown error");
#ifdef HL_WIN
	vstring *result = realtime_string_of_ustr((const uchar *)message);
#else
	vstring *result = realtime_string_from_utf8(message);
#endif
	free(message);
	return result;
}
DEFINE_PRIM(_STRING,__fs_error_message,_NO_ARG);

HL_PRIM realtime_fs_root *HL_NAME(__fs_root_open)( vstring *path ) {
	realtime_fs_root *root = (realtime_fs_root *)hl_gc_alloc_finalizer(sizeof(realtime_fs_root));
	root->finalize = realtime_fs_root_finalize;
	root->open = false;
	REALTIME_FS_PATH(native,path);
	bool opened = realtime_fs_root_open(&root->directory,native);
	REALTIME_FS_PATH_END(native);
	if( !opened ) return NULL;
	root->open = true;
	return root;
}
DEFINE_PRIM(_ABSTRACT(realtime_fs_root),__fs_root_open,_STRING);

HL_PRIM void HL_NAME(__fs_root_close)( realtime_fs_root *root ) {
	if( root != NULL ) realtime_fs_root_finalize(root);
}
DEFINE_PRIM(_VOID,__fs_root_close,_ABSTRACT(realtime_fs_root));

/* The whole file, or null. */
HL_PRIM realtime_bytes *HL_NAME(__fs_read)( realtime_fs_root *root, vstring *path ) {
	unsigned char *data = NULL;
	int length = 0;
	REALTIME_FS_PATH(native,path);
	bool read = realtime_fs_read(realtime_fs_resolver(root),native,&data,&length);
	REALTIME_FS_PATH_END(native);
	if( !read ) return NULL;
	/* The bytes adopt the buffer, which they free with free() as they do their own. */
	realtime_bytes *result = realtime_bytes_make(0);
	if( length == 0 ) free(data);
	else {
		result->data = data;
		result->length = length;
	}
	return result;
}
DEFINE_PRIM(_ABSTRACT(realtime_bytes),__fs_read,_ABSTRACT(realtime_fs_root) _STRING);

/* The whole file as UTF-8 text, or null; a file holding a NUL character fails as Io (REALTIME_FS_TEXT_NUL). */
HL_PRIM vstring *HL_NAME(__fs_read_text)( realtime_fs_root *root, vstring *path ) {
	unsigned char *data = NULL;
	int length = 0;
	REALTIME_FS_PATH(native,path);
	bool read = realtime_fs_read(realtime_fs_resolver(root),native,&data,&length);
	REALTIME_FS_PATH_END(native);
	if( !read ) return NULL;
	if( length > 0 && memchr(data,0,(size_t)length) != NULL ) {
		free(data);
		realtime_fs_kind = REALTIME_FS_IO;
		realtime_fs_code = REALTIME_FS_TEXT_NUL;
		return NULL;
	}
	data[length] = 0;
	vstring *result = realtime_string_from_utf8((const char *)data);
	free(data);
	return result;
}
DEFINE_PRIM(_STRING,__fs_read_text,_ABSTRACT(realtime_fs_root) _STRING);

/* What kind of entry is at `path` (std.fs.EntryKind), or -1. */
HL_PRIM int HL_NAME(__fs_kind)( realtime_fs_root *root, vstring *path, bool follow ) {
	int kind = -1;
	REALTIME_FS_PATH(native,path);
	bool found = realtime_fs_kind_at(realtime_fs_resolver(root),native,follow,&kind);
	REALTIME_FS_PATH_END(native);
	return found ? kind : -1;
}
DEFINE_PRIM(_I32,__fs_kind,_ABSTRACT(realtime_fs_root) _STRING _BOOL);

/* `path` as an absolute path, its links resolved on POSIX, or null. */
HL_PRIM vstring *HL_NAME(__fs_absolute)( vstring *path ) {
	REALTIME_FS_PATH(native,path);
	realtime_fs_char *absolute = realtime_fs_absolute(native);
	REALTIME_FS_PATH_END(native);
	if( absolute == NULL ) return NULL;
#ifdef HL_WIN
	vstring *result = realtime_string_of_ustr((const uchar *)absolute);
#else
	vstring *result = realtime_string_from_utf8(absolute);
#endif
	free(absolute);
	return result;
}
DEFINE_PRIM(_STRING,__fs_absolute,_STRING);

/* What `path` names, absolute with its links resolved on every system, or null. */
HL_PRIM vstring *HL_NAME(__fs_canonical)( vstring *path ) {
	REALTIME_FS_PATH(native,path);
	realtime_fs_char *canonical = realtime_fs_canonical(native);
	REALTIME_FS_PATH_END(native);
	if( canonical == NULL ) return NULL;
#ifdef HL_WIN
	vstring *result = realtime_string_of_ustr((const uchar *)canonical);
#else
	vstring *result = realtime_string_from_utf8(canonical);
#endif
	free(canonical);
	return result;
}
DEFINE_PRIM(_STRING,__fs_canonical,_STRING);

/* Haxe's FileStat of `path` as eleven Ints (gid, uid, atime, mtime, ctime, size, dev, ino, nlink, rdev, mode), or null. */
HL_PRIM varray *HL_NAME(__fs_stat)( vstring *path ) {
	int values[11];
	REALTIME_FS_PATH(native,path);
	bool found = realtime_fs_stat(native,values);
	REALTIME_FS_PATH_END(native);
	if( !found ) return NULL;
	varray *result = hl_alloc_array(&hlt_i32,11);
	memcpy(hl_aptr(result,int),values,sizeof(values));
	return result;
}
DEFINE_PRIM(_ARR,__fs_stat,_STRING);

/* Writes `content` as `mode` says: replacing the file, adding to its end, or only creating it. */
HL_PRIM bool HL_NAME(__fs_write)( realtime_fs_root *root, vstring *path, realtime_bytes *content, int mode ) {
	REALTIME_FS_PATH(native,path);
	bool written = realtime_fs_write(realtime_fs_resolver(root),native,content->data,content->length,mode);
	REALTIME_FS_PATH_END(native);
	return written;
}
DEFINE_PRIM(_BOOL,__fs_write,_ABSTRACT(realtime_fs_root) _STRING _ABSTRACT(realtime_bytes) _I32);

/* Puts `content` at `path` in one step; without `replace`, fails where something is already there. */
HL_PRIM bool HL_NAME(__fs_write_atomic)( realtime_fs_root *root, vstring *path, realtime_bytes *content, bool replace ) {
	REALTIME_FS_PATH(native,path);
	bool written = realtime_fs_write_atomic(realtime_fs_resolver(root),native,content->data,content->length,replace);
	REALTIME_FS_PATH_END(native);
	return written;
}
DEFINE_PRIM(_BOOL,__fs_write_atomic,_ABSTRACT(realtime_fs_root) _STRING _ABSTRACT(realtime_bytes) _BOOL);

/* Fills `out` with what is at `path`: its kind (std.fs.EntryKind) as an Int32 at 0, its size in bytes as an Int64 at 8,
   and its last modification as Unix seconds, a Float64 at 16. A symbolic link is described itself, not what it points
   to, unless `follow`. */
HL_PRIM bool HL_NAME(__fs_metadata)( realtime_fs_root *root, vstring *path, bool follow, realtime_bytes *out ) {
	if( out == NULL || out->length < 24 ) hl_error("metadata buffer is too small");
	realtime_fs_metadata metadata;
	REALTIME_FS_PATH(native,path);
	bool found = realtime_fs_metadata_of(realtime_fs_resolver(root),native,follow,&metadata);
	REALTIME_FS_PATH_END(native);
	if( !found ) return false;
	int32_t kind = metadata.kind;
	memcpy(out->data,&kind,4);
	memcpy(out->data + 8,&metadata.size,8);
	memcpy(out->data + 16,&metadata.modified,8);
	return true;
}
DEFINE_PRIM(_BOOL,__fs_metadata,_ABSTRACT(realtime_fs_root) _STRING _BOOL _ABSTRACT(realtime_bytes));

typedef struct {
	varray *array;
	vstring **items;
	int capacity;
	int count;
	vstring *markers[4];
} realtime_fs_listing;

static void realtime_fs_listed( void *context, const void *name, int length, int kind ) {
	realtime_fs_listing *listing = (realtime_fs_listing *)context;
	realtime_directory_entries_reserve(&listing->array,&listing->items,&listing->capacity,listing->count + 2,listing->count);
#ifdef HL_WIN
	listing->items[listing->count++] = realtime_string_copy((const uchar *)name,length);
#else
	char *text = (char *)malloc((size_t)length + 1);
	if( text == NULL ) hl_error("Could not allocate a file name");
	memcpy(text,name,(size_t)length);
	text[length] = 0;
	listing->items[listing->count++] = realtime_string_from_utf8(text);
	free(text);
#endif
	listing->items[listing->count++] = listing->markers[kind];
}

/* The entries of a directory as name and kind (std.fs.EntryKind as one character: "f", "d", "l", "o"), in the order
   the system lists them, without "." and "..". Null on failure. */
HL_PRIM varray *HL_NAME(__fs_list)( realtime_fs_root *root, vstring *path ) {
	realtime_fs_listing listing;
	memset(&listing,0,sizeof(listing));
	listing.markers[REALTIME_FS_FILE] = realtime_string_from_utf8("f");
	listing.markers[REALTIME_FS_DIRECTORY] = realtime_string_from_utf8("d");
	listing.markers[REALTIME_FS_LINK] = realtime_string_from_utf8("l");
	listing.markers[REALTIME_FS_OTHER] = realtime_string_from_utf8("o");
	REALTIME_FS_PATH(native,path);
	bool listed = realtime_fs_list(realtime_fs_resolver(root),native,realtime_fs_listed,&listing);
	REALTIME_FS_PATH_END(native);
	if( !listed ) return NULL;
	if( listing.array == NULL ) listing.array = hl_alloc_array(hl_string_type,0);
	listing.array->size = listing.count;
	return listing.array;
}
DEFINE_PRIM(_ARR,__fs_list,_ABSTRACT(realtime_fs_root) _STRING);

/* Creates the directory `path`, whose parent must exist. */
HL_PRIM bool HL_NAME(__fs_create_directory)( realtime_fs_root *root, vstring *path ) {
	REALTIME_FS_PATH(native,path);
	bool done = realtime_fs_create_directory(realtime_fs_resolver(root),native);
	REALTIME_FS_PATH_END(native);
	return done;
}
DEFINE_PRIM(_BOOL,__fs_create_directory,_ABSTRACT(realtime_fs_root) _STRING);

/* Deletes the file or symbolic link `path`; a link to a directory goes, not the directory. */
HL_PRIM bool HL_NAME(__fs_delete_file)( realtime_fs_root *root, vstring *path ) {
	REALTIME_FS_PATH(native,path);
	bool done = realtime_fs_delete_file(realtime_fs_resolver(root),native);
	REALTIME_FS_PATH_END(native);
	return done;
}
DEFINE_PRIM(_BOOL,__fs_delete_file,_ABSTRACT(realtime_fs_root) _STRING);

/* Removes the empty directory `path`. */
HL_PRIM bool HL_NAME(__fs_delete_directory)( realtime_fs_root *root, vstring *path ) {
	REALTIME_FS_PATH(native,path);
	bool done = realtime_fs_delete_directory(realtime_fs_resolver(root),native);
	REALTIME_FS_PATH_END(native);
	return done;
}
DEFINE_PRIM(_BOOL,__fs_delete_directory,_ABSTRACT(realtime_fs_root) _STRING);

/* Moves `path` to `target`, replacing a file there. */
HL_PRIM bool HL_NAME(__fs_rename)( realtime_fs_root *root, vstring *path, vstring *target ) {
	REALTIME_FS_PATH(from,path);
	REALTIME_FS_PATH(to,target);
	bool moved = realtime_fs_rename(realtime_fs_resolver(root),from,to);
	REALTIME_FS_PATH_END(from);
	REALTIME_FS_PATH_END(to);
	return moved;
}
DEFINE_PRIM(_BOOL,__fs_rename,_ABSTRACT(realtime_fs_root) _STRING _STRING);

/* An open file as std.fs.FileHandle holds it: closed when it is, or when it is collected. */
typedef struct {
	void (*finalize)( void * );
	realtime_fs_stream stream;
	bool open;
} realtime_fs_handle;

static void realtime_fs_handle_finalize( void *value ) {
	realtime_fs_handle *handle = (realtime_fs_handle *)value;
	if( handle->open ) realtime_fs_stream_close(&handle->stream);
	handle->open = false;
}

/* Opens the file `path` as `mode` says (std.fs.OpenMode's index), or null. */
HL_PRIM realtime_fs_handle *HL_NAME(__fs_stream_open)( realtime_fs_root *root, vstring *path, int mode ) {
	realtime_fs_handle *handle = (realtime_fs_handle *)hl_gc_alloc_finalizer(sizeof(realtime_fs_handle));
	handle->finalize = realtime_fs_handle_finalize;
	handle->open = false;
	REALTIME_FS_PATH(native,path);
	bool opened = realtime_fs_stream_open(realtime_fs_resolver(root),native,mode,&handle->stream);
	REALTIME_FS_PATH_END(native);
	if( !opened ) return NULL;
	handle->open = true;
	return handle;
}
DEFINE_PRIM(_ABSTRACT(realtime_fs_handle),__fs_stream_open,_ABSTRACT(realtime_fs_root) _STRING _I32);

static bool realtime_fs_handle_live( realtime_fs_handle *handle ) {
	if( handle == NULL || !handle->open ) hl_error("std.fs.FileHandle is closed");
	return true;
}

/* Reads up to `length` bytes into `buffer` at `offset`: how many, 0 at the end, -1 on failure. */
HL_PRIM int HL_NAME(__fs_stream_read)( realtime_fs_handle *handle, realtime_bytes *buffer, int offset, int length ) {
	realtime_fs_handle_live(handle);
	if( offset < 0 || length < 0 || offset > buffer->length - length ) hl_error("read outside the buffer");
	if( length == 0 ) return 0;
	hl_blocking(true);
	int read = realtime_fs_stream_read(&handle->stream,buffer->data + offset,length);
	hl_blocking(false);
	return read;
}
DEFINE_PRIM(_I32,__fs_stream_read,_ABSTRACT(realtime_fs_handle) _ABSTRACT(realtime_bytes) _I32 _I32);

/* Writes `length` bytes of `buffer` from `offset`, all of them, or answers false. */
HL_PRIM bool HL_NAME(__fs_stream_write)( realtime_fs_handle *handle, realtime_bytes *buffer, int offset, int length ) {
	realtime_fs_handle_live(handle);
	if( offset < 0 || length < 0 || offset > buffer->length - length ) hl_error("write outside the buffer");
	hl_blocking(true);
	bool written = realtime_fs_stream_write(&handle->stream,buffer->data + offset,length);
	hl_blocking(false);
	return written;
}
DEFINE_PRIM(_BOOL,__fs_stream_write,_ABSTRACT(realtime_fs_handle) _ABSTRACT(realtime_bytes) _I32 _I32);

/* Moves by the Int64 at 0 of `place` from `origin` (0 start, 1 here, 2 end), writing the new position there. */
HL_PRIM bool HL_NAME(__fs_stream_seek)( realtime_fs_handle *handle, realtime_bytes *place, int origin ) {
	realtime_fs_handle_live(handle);
	if( place == NULL || place->length < 8 ) hl_error("seek buffer is too small");
	int64_t offset, position = 0;
	memcpy(&offset,place->data,8);
	if( !realtime_fs_stream_seek(&handle->stream,offset,origin,&position) ) return false;
	memcpy(place->data,&position,8);
	return true;
}
DEFINE_PRIM(_BOOL,__fs_stream_seek,_ABSTRACT(realtime_fs_handle) _ABSTRACT(realtime_bytes) _I32);

/* Writes the file's size, an Int64, at 0 of `out`. */
HL_PRIM bool HL_NAME(__fs_stream_size)( realtime_fs_handle *handle, realtime_bytes *out ) {
	realtime_fs_handle_live(handle);
	if( out == NULL || out->length < 8 ) hl_error("size buffer is too small");
	int64_t size = 0;
	if( !realtime_fs_stream_size(&handle->stream,&size) ) return false;
	memcpy(out->data,&size,8);
	return true;
}
DEFINE_PRIM(_BOOL,__fs_stream_size,_ABSTRACT(realtime_fs_handle) _ABSTRACT(realtime_bytes));

/* Makes the file as long as the Int64 at 0 of `length`, cutting it or padding it with zeros. */
HL_PRIM bool HL_NAME(__fs_stream_set_length)( realtime_fs_handle *handle, realtime_bytes *length ) {
	realtime_fs_handle_live(handle);
	if( length == NULL || length->length < 8 ) hl_error("length buffer is too small");
	int64_t value;
	memcpy(&value,length->data,8);
	return realtime_fs_stream_set_length(&handle->stream,value);
}
DEFINE_PRIM(_BOOL,__fs_stream_set_length,_ABSTRACT(realtime_fs_handle) _ABSTRACT(realtime_bytes));

/* Waits until what was written is on the disk. */
HL_PRIM bool HL_NAME(__fs_stream_sync)( realtime_fs_handle *handle ) {
	realtime_fs_handle_live(handle);
	hl_blocking(true);
	bool synced = realtime_fs_stream_sync(&handle->stream);
	hl_blocking(false);
	return synced;
}
DEFINE_PRIM(_BOOL,__fs_stream_sync,_ABSTRACT(realtime_fs_handle));

/* Closes the file; false when the system reported a failure doing so (a write it could not finish). */
HL_PRIM bool HL_NAME(__fs_stream_close)( realtime_fs_handle *handle ) {
	if( handle == NULL || !handle->open ) return true;
	handle->open = false;
	return realtime_fs_stream_close(&handle->stream);
}
DEFINE_PRIM(_BOOL,__fs_stream_close,_ABSTRACT(realtime_fs_handle));
