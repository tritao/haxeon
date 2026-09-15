typedef struct haxeon_gc_handle {
	void (*finalize)( void * );
	vdynamic *value;
	bool closed;
} haxeon_gc_handle;

static void haxeon_gc_handle_finalize( void *value ) {
	haxeon_gc_handle *handle = (haxeon_gc_handle *)value;
	if( handle->closed ) return;
	hl_remove_root(&handle->value);
	handle->value = NULL;
	handle->closed = true;
}

HL_PRIM haxeon_gc_handle *HL_NAME(native_gc_handle_create)( vdynamic *value ) {
	haxeon_gc_handle *handle = (haxeon_gc_handle *)hl_gc_alloc_finalizer(sizeof(haxeon_gc_handle));
	memset(handle,0,sizeof(*handle));
	handle->finalize = haxeon_gc_handle_finalize;
	handle->value = value;
	hl_add_root(&handle->value);
	return handle;
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
	if( handle == NULL || handle->closed ) return false;
	hl_remove_root(&handle->value);
	handle->value = NULL;
	handle->closed = true;
	return true;
}

HL_PRIM bool HL_NAME(native_gc_handle_is_closed)( haxeon_gc_handle *handle ) {
	return handle == NULL || handle->closed;
}

HL_PRIM void HL_NAME(native_gc_major)() {
	hl_gc_major();
}
