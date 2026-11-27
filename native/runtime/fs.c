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

/* Writes `content` as `mode` says: replacing the file, adding to its end, or only creating it. */
HL_PRIM bool HL_NAME(__fs_write)( realtime_fs_root *root, vstring *path, realtime_bytes *content, int mode ) {
	REALTIME_FS_PATH(native,path);
	bool written = realtime_fs_write(realtime_fs_resolver(root),native,content->data,content->length,mode);
	REALTIME_FS_PATH_END(native);
	return written;
}
DEFINE_PRIM(_BOOL,__fs_write,_ABSTRACT(realtime_fs_root) _STRING _ABSTRACT(realtime_bytes) _I32);

HL_PRIM bool HL_NAME(__fs_write_atomic)( realtime_fs_root *root, vstring *path, realtime_bytes *content ) {
	REALTIME_FS_PATH(native,path);
	bool written = realtime_fs_write_atomic(realtime_fs_resolver(root),native,content->data,content->length);
	REALTIME_FS_PATH_END(native);
	return written;
}
DEFINE_PRIM(_BOOL,__fs_write_atomic,_ABSTRACT(realtime_fs_root) _STRING _ABSTRACT(realtime_bytes));

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
