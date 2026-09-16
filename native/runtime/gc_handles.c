typedef struct haxeon_gc_handle {
	void (*finalize)( void * );
	vdynamic *value;
	bool closed;
	void *owner;
	struct haxeon_gc_handle_owner_link *owner_link;
} haxeon_gc_handle;

typedef struct haxeon_gc_handle_owner_link {
	haxeon_gc_handle *handle;
	void *owner;
	struct haxeon_gc_handle_owner_link *next;
} haxeon_gc_handle_owner_link;

static haxeon_gc_handle_owner_link *haxeon_gc_handle_owners = NULL;

static void haxeon_gc_handle_unlink_owner( haxeon_gc_handle *handle ) {
	haxeon_gc_handle_owner_link **cursor;
	haxeon_gc_handle_owner_link *link;
	if( handle == NULL || handle->owner_link == NULL ) return;
	link = handle->owner_link;
	cursor = &haxeon_gc_handle_owners;
	while( *cursor != NULL && *cursor != link ) cursor = &(*cursor)->next;
	if( *cursor == link ) {
		*cursor = link->next;
		hl_remove_root(&link->handle);
		free(link);
	}
	handle->owner_link = NULL;
	handle->owner = NULL;
}

static bool haxeon_gc_handle_close_internal( haxeon_gc_handle *handle ) {
	if( handle == NULL || handle->closed ) return false;
	hl_remove_root(&handle->value);
	handle->value = NULL;
	handle->closed = true;
	haxeon_gc_handle_unlink_owner(handle);
	return true;
}

static void haxeon_gc_handle_finalize( void *value ) {
	haxeon_gc_handle *handle = (haxeon_gc_handle *)value;
	haxeon_gc_handle_close_internal(handle);
}

static haxeon_gc_handle *haxeon_gc_handle_create( vdynamic *value, void *owner ) {
	haxeon_gc_handle_owner_link *link = NULL;
	haxeon_gc_handle *handle = (haxeon_gc_handle *)hl_gc_alloc_finalizer(sizeof(haxeon_gc_handle));
	memset(handle,0,sizeof(*handle));
	handle->finalize = haxeon_gc_handle_finalize;
	handle->value = value;
	handle->owner = owner;
	if( owner != NULL ) {
		link = (haxeon_gc_handle_owner_link *)malloc(sizeof(*link));
		if( link == NULL ) hl_error("Could not allocate a GC handle owner link");
		link->handle = handle;
		link->owner = owner;
		link->next = haxeon_gc_handle_owners;
		haxeon_gc_handle_owners = link;
		handle->owner_link = link;
		hl_add_root(&link->handle);
		hl_add_root_owner(&handle->value,owner);
	} else
		hl_add_root(&handle->value);
	return handle;
}

HL_PRIM haxeon_gc_handle *HL_NAME(native_gc_handle_create)( vdynamic *value ) {
	return haxeon_gc_handle_create(value,NULL);
}

HL_PRIM haxeon_gc_handle *HL_NAME(native_gc_handle_create_owned)( vdynamic *value, vbyte *owner ) {
	return haxeon_gc_handle_create(value,owner);
}

HL_PRIM vdynamic *HL_NAME(native_gc_handle_get)( haxeon_gc_handle *handle ) {
	if( handle == NULL || handle->closed ) return NULL;
	return handle->value;
}

HL_PRIM void HL_NAME(native_gc_handle_set)( haxeon_gc_handle *handle, vdynamic *value ) {
	if( handle == NULL || handle->closed ) hl_error("Cannot update a closed GC handle");
	handle->value = value;
}

HL_PRIM vbyte *HL_NAME(native_gc_handle_raw)( haxeon_gc_handle *handle ) {
	if( handle == NULL || handle->closed ) return NULL;
	return (vbyte *)handle->value;
}

HL_PRIM bool HL_NAME(native_gc_handle_close)( haxeon_gc_handle *handle ) {
	return haxeon_gc_handle_close_internal(handle);
}

HL_PRIM bool HL_NAME(native_gc_handle_is_closed)( haxeon_gc_handle *handle ) {
	return handle == NULL || handle->closed;
}

int haxeon_gc_handle_owner_count( void *owner ) {
	haxeon_gc_handle_owner_link *link;
	int count = 0;
	if( owner == NULL ) return 0;
	for(link=haxeon_gc_handle_owners;link;link=link->next)
		if( link->owner == owner && link->handle != NULL && !link->handle->closed ) count++;
	return count;
}

void haxeon_gc_handle_detach_owner( void *owner ) {
	haxeon_gc_handle_owner_link *link, *next;
	if( owner == NULL ) return;
	for(link=haxeon_gc_handle_owners;link;link=next) {
		next = link->next;
		if( link->owner == owner ) haxeon_gc_handle_close_internal(link->handle);
	}
}

HL_PRIM void HL_NAME(native_gc_major)() {
	hl_gc_major();
}
