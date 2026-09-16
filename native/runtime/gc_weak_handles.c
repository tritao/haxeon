typedef struct haxeon_gc_weak_handle {
	void (*finalize)( void * );
	vdynamic *value;
	bool closed;
} haxeon_gc_weak_handle;

static atomic_flag haxeon_gc_weak_handle_lock = ATOMIC_FLAG_INIT;

static void haxeon_gc_weak_handle_lock_acquire( void ) {
	while( atomic_flag_test_and_set_explicit(&haxeon_gc_weak_handle_lock,memory_order_acquire) ) {}
}

static void haxeon_gc_weak_handle_lock_release( void ) {
	atomic_flag_clear_explicit(&haxeon_gc_weak_handle_lock,memory_order_release);
}

static void haxeon_gc_weak_handle_finalize( void *value ) {
	haxeon_gc_weak_handle *handle = (haxeon_gc_weak_handle *)value;
	bool close;
	haxeon_gc_weak_handle_lock_acquire();
	close = !handle->closed;
	handle->closed = true;
	haxeon_gc_weak_handle_lock_release();
	if( close ) {
		hl_weak_root_set(&handle->value,NULL);
		hl_remove_weak_root(&handle->value);
	}
}

static haxeon_gc_weak_handle *haxeon_gc_weak_handle_create( vdynamic *value ) {
	haxeon_gc_weak_handle *handle = (haxeon_gc_weak_handle *)hl_gc_alloc_finalizer(sizeof(haxeon_gc_weak_handle));
	memset(handle,0,sizeof(*handle));
	handle->finalize = haxeon_gc_weak_handle_finalize;
	handle->value = value;
	hl_add_weak_root(&handle->value);
	return handle;
}

HL_PRIM haxeon_gc_weak_handle *HL_NAME(native_gc_weak_handle_create)( vdynamic *value ) {
	return haxeon_gc_weak_handle_create(value);
}

HL_PRIM vdynamic *HL_NAME(native_gc_weak_handle_get)( haxeon_gc_weak_handle *handle ) {
	vdynamic *value;
	if( handle == NULL ) return NULL;
	haxeon_gc_weak_handle_lock_acquire();
	if( handle->closed ) {
		haxeon_gc_weak_handle_lock_release();
		return NULL;
	}
	haxeon_gc_weak_handle_lock_release();
	/* HashLink's weak-root operations may wait on the collector, so do not
	   hold the handle lock while entering the collector lock. */
	value = (vdynamic *)hl_weak_root_get(&handle->value);
	haxeon_gc_weak_handle_lock_acquire();
	if( handle->closed ) value = NULL;
	haxeon_gc_weak_handle_lock_release();
	return value;
}

HL_PRIM void HL_NAME(native_gc_weak_handle_set)( haxeon_gc_weak_handle *handle, vdynamic *value ) {
	if( handle == NULL ) hl_error("Cannot update a null weak GC handle");
	haxeon_gc_weak_handle_lock_acquire();
	if( handle->closed ) {
		haxeon_gc_weak_handle_lock_release();
		hl_error("Cannot update a closed weak GC handle");
	}
	haxeon_gc_weak_handle_lock_release();
	/* Match the strong-root barrier: the collector lock and handle lock must
	   never be acquired in opposite order by a finalizer. */
	hl_weak_root_set(&handle->value,value);
	haxeon_gc_weak_handle_lock_acquire();
	bool closed = handle->closed;
	haxeon_gc_weak_handle_lock_release();
	/* A close may have raced the collector-safe update. A closed weak handle
	   must not retain a value in its now-unregistered slot. */
	if( closed ) hl_weak_root_set(&handle->value,NULL);
}

HL_PRIM vbyte *HL_NAME(native_gc_weak_handle_raw)( haxeon_gc_weak_handle *handle ) {
	return (vbyte *)HL_NAME(native_gc_weak_handle_get)(handle);
}

HL_PRIM bool HL_NAME(native_gc_weak_handle_close)( haxeon_gc_weak_handle *handle ) {
	bool close;
	if( handle == NULL ) return false;
	haxeon_gc_weak_handle_lock_acquire();
	close = !handle->closed;
	handle->closed = true;
	haxeon_gc_weak_handle_lock_release();
	if( close ) {
		hl_weak_root_set(&handle->value,NULL);
		hl_remove_weak_root(&handle->value);
	}
	return close;
}

HL_PRIM bool HL_NAME(native_gc_weak_handle_is_closed)( haxeon_gc_weak_handle *handle ) {
	bool closed;
	if( handle == NULL ) return true;
	haxeon_gc_weak_handle_lock_acquire();
	closed = handle->closed;
	haxeon_gc_weak_handle_lock_release();
	return closed;
}
