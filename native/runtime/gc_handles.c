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
static atomic_flag haxeon_gc_handle_registry_lock = ATOMIC_FLAG_INIT;

/* HashLink root operations may wait on the GC, so the registry lock only
   protects the list and handle state, never a root add/remove operation. */
static void haxeon_gc_handle_lock( void ) {
	while( atomic_flag_test_and_set_explicit(&haxeon_gc_handle_registry_lock,memory_order_acquire) ) {}
}

static void haxeon_gc_handle_unlock( void ) {
	atomic_flag_clear_explicit(&haxeon_gc_handle_registry_lock,memory_order_release);
}

static haxeon_gc_handle_owner_link *haxeon_gc_handle_unlink_owner_locked( haxeon_gc_handle *handle ) {
	haxeon_gc_handle_owner_link **cursor;
	haxeon_gc_handle_owner_link *link;
	if( handle == NULL || handle->owner_link == NULL ) return NULL;
	link = handle->owner_link;
	cursor = &haxeon_gc_handle_owners;
	while( *cursor != NULL && *cursor != link ) cursor = &(*cursor)->next;
	if( *cursor != link ) return NULL;
	*cursor = link->next;
	handle->owner_link = NULL;
	handle->owner = NULL;
	return link;
}

static void haxeon_gc_handle_release_owner_link( haxeon_gc_handle_owner_link *link ) {
	if( link == NULL ) return;
	hl_remove_root(&link->handle);
	free(link);
}

static bool haxeon_gc_handle_prepare_close_locked( haxeon_gc_handle *handle, haxeon_gc_handle_owner_link **owner_link ) {
	if( owner_link != NULL ) *owner_link = NULL;
	if( handle == NULL || handle->closed ) return false;
	handle->closed = true;
	if( owner_link != NULL ) *owner_link = haxeon_gc_handle_unlink_owner_locked(handle);
	return true;
}

static bool haxeon_gc_handle_close_internal( haxeon_gc_handle *handle ) {
	haxeon_gc_handle_owner_link *owner_link = NULL;
	bool closed;
	haxeon_gc_handle_lock();
	closed = haxeon_gc_handle_prepare_close_locked(handle,&owner_link);
	haxeon_gc_handle_unlock();
	if( closed ) {
		/* Clear the registered slot under HashLink's collector lock before
		   unregistering it. */
		hl_root_set(&handle->value,NULL);
		hl_remove_root(&handle->value);
		haxeon_gc_handle_release_owner_link(owner_link);
	}
	return closed;
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
		/* Root the pair before publishing it to the owner registry. */
		hl_add_root(&link->handle);
		hl_add_root_owner(&handle->value,owner);
		haxeon_gc_handle_lock();
		link->next = haxeon_gc_handle_owners;
		haxeon_gc_handle_owners = link;
		handle->owner_link = link;
		haxeon_gc_handle_unlock();
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

HL_PRIM haxeon_gc_handle *HL_NAME(native_gc_handle_create_owned_raw)( vdynamic *value, vbyte *owner ) {
	return haxeon_gc_handle_create(value,owner);
}

HL_PRIM vdynamic *HL_NAME(native_gc_handle_get)( haxeon_gc_handle *handle ) {
	vdynamic *value;
	if( handle == NULL ) return NULL;
	haxeon_gc_handle_lock();
	if( handle->closed ) {
		haxeon_gc_handle_unlock();
		return NULL;
	}
	haxeon_gc_handle_unlock();
	/* Read the registered slot under HashLink's collector lock. The handle
	   lock must remain outside this operation for the same finalizer ordering
	   rule used by native_gc_handle_set. */
	value = (vdynamic *)hl_root_get(&handle->value);
	haxeon_gc_handle_lock();
	if( handle->closed ) value = NULL;
	haxeon_gc_handle_unlock();
	return value;
}

HL_PRIM void HL_NAME(native_gc_handle_set)( haxeon_gc_handle *handle, vdynamic *value ) {
	bool closed;
	haxeon_gc_handle_lock();
	if( handle == NULL || handle->closed ) {
		haxeon_gc_handle_unlock();
		hl_error("Cannot update a closed GC handle");
	}
	haxeon_gc_handle_unlock();
	/* Update the registered slot under HashLink's collector lock. Do not hold
	   the handle registry lock across this operation: a collector finalizer may
	   need that lock while a mutator waits for the world lock. */
	hl_root_set(&handle->value,value);
	haxeon_gc_handle_lock();
	closed = handle->closed;
	haxeon_gc_handle_unlock();
	/* Close may have raced the collector-safe update. A closed handle must
	   never leave a managed value in its now-unregistered slot. */
	if( closed ) hl_root_set(&handle->value,NULL);
}

HL_PRIM vbyte *HL_NAME(native_gc_handle_raw)( haxeon_gc_handle *handle ) {
	return (vbyte *)HL_NAME(native_gc_handle_get)(handle);
}

HL_PRIM bool HL_NAME(native_gc_handle_close)( haxeon_gc_handle *handle ) {
	return haxeon_gc_handle_close_internal(handle);
}

HL_PRIM bool HL_NAME(native_gc_handle_is_closed)( haxeon_gc_handle *handle ) {
	bool closed;
	haxeon_gc_handle_lock();
	closed = handle == NULL || handle->closed;
	haxeon_gc_handle_unlock();
	return closed;
}

int haxeon_gc_handle_owner_count( void *owner ) {
	haxeon_gc_handle_owner_link *link;
	int count = 0;
	if( owner == NULL ) return 0;
	haxeon_gc_handle_lock();
	for(link=haxeon_gc_handle_owners;link;link=link->next)
		if( link->owner == owner && link->handle != NULL && !link->handle->closed ) count++;
	haxeon_gc_handle_unlock();
	return count;
}

void haxeon_gc_handle_detach_owner( void *owner ) {
	haxeon_gc_handle_owner_link *link;
	haxeon_gc_handle *handle;
	bool closed;
	if( owner == NULL ) return;
	while( true ) {
		haxeon_gc_handle_lock();
		for(link=haxeon_gc_handle_owners;link;link=link->next)
			if( link->owner == owner ) break;
		if( link == NULL ) {
			haxeon_gc_handle_unlock();
			return;
		}
		handle = link->handle;
		closed = haxeon_gc_handle_prepare_close_locked(handle,&link);
		haxeon_gc_handle_unlock();
		if( closed ) {
			hl_root_set(&handle->value,NULL);
			hl_remove_root(&handle->value);
			haxeon_gc_handle_release_owner_link(link);
		}
	}
}

HL_PRIM void HL_NAME(native_gc_major)() {
	hl_gc_major();
}

typedef struct haxeon_gc_stats {
	int64_t total_allocated;
	int64_t allocation_count;
	int64_t heap_bytes;
	int64_t collection_count;
	int64_t mark_micros;
} haxeon_gc_stats;

static haxeon_gc_stats *haxeon_gc_stats_require( haxeon_gc_stats *stats ) {
	if( stats == NULL ) hl_error("GC statistics snapshot is null");
	return stats;
}

HL_PRIM haxeon_gc_stats *HL_NAME(native_gc_stats_snapshot)() {
	haxeon_gc_stats *stats = (haxeon_gc_stats *)hl_gc_alloc_raw(sizeof(haxeon_gc_stats));
	unsigned long long total_allocated, allocation_count, heap_bytes, collection_count, mark_micros;
	hl_gc_profile_stats(&total_allocated,&allocation_count,&heap_bytes,&collection_count,&mark_micros);
	stats->total_allocated = (int64_t)total_allocated;
	stats->allocation_count = (int64_t)allocation_count;
	stats->heap_bytes = (int64_t)heap_bytes;
	stats->collection_count = (int64_t)collection_count;
	stats->mark_micros = (int64_t)mark_micros;
	return stats;
}

HL_PRIM int64_t HL_NAME(native_gc_stats_total_allocated)( haxeon_gc_stats *stats ) {
	return haxeon_gc_stats_require(stats)->total_allocated;
}

HL_PRIM int64_t HL_NAME(native_gc_stats_allocation_count)( haxeon_gc_stats *stats ) {
	return haxeon_gc_stats_require(stats)->allocation_count;
}

HL_PRIM int64_t HL_NAME(native_gc_stats_heap_bytes)( haxeon_gc_stats *stats ) {
	return haxeon_gc_stats_require(stats)->heap_bytes;
}

HL_PRIM int64_t HL_NAME(native_gc_stats_collection_count)( haxeon_gc_stats *stats ) {
	return haxeon_gc_stats_require(stats)->collection_count;
}

HL_PRIM int64_t HL_NAME(native_gc_stats_mark_micros)( haxeon_gc_stats *stats ) {
	return haxeon_gc_stats_require(stats)->mark_micros;
}
