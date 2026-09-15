HL_PRIM hl_mutex *HL_NAME(native_mutex_alloc)( bool gcThread ) {
	return hl_mutex_alloc(gcThread);
}

HL_PRIM void HL_NAME(native_mutex_acquire)( hl_mutex *mutex ) {
	if( mutex == NULL ) hl_error("Cannot acquire a null mutex");
	hl_mutex_acquire(mutex);
}

HL_PRIM bool HL_NAME(native_mutex_try_acquire)( hl_mutex *mutex ) {
	if( mutex == NULL ) hl_error("Cannot try-acquire a null mutex");
	return hl_mutex_try_acquire(mutex);
}

HL_PRIM void HL_NAME(native_mutex_release)( hl_mutex *mutex ) {
	if( mutex == NULL ) hl_error("Cannot release a null mutex");
	hl_mutex_release(mutex);
}

HL_PRIM void HL_NAME(native_mutex_close)( hl_mutex *mutex ) {
	if( mutex != NULL ) hl_mutex_free(mutex);
}

HL_PRIM hl_condition *HL_NAME(native_condition_alloc)() {
	return hl_condition_alloc();
}

HL_PRIM void HL_NAME(native_condition_acquire)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot acquire a null condition variable");
	hl_condition_acquire(condition);
}

HL_PRIM bool HL_NAME(native_condition_try_acquire)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot try-acquire a null condition variable");
	return hl_condition_try_acquire(condition);
}

HL_PRIM void HL_NAME(native_condition_release)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot release a null condition variable");
	hl_condition_release(condition);
}

HL_PRIM void HL_NAME(native_condition_wait)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot wait on a null condition variable");
	hl_condition_wait(condition);
}

HL_PRIM bool HL_NAME(native_condition_timed_wait)( hl_condition *condition, double timeout ) {
	if( condition == NULL || timeout < 0 ) hl_error("Condition variable timed wait requires a non-negative timeout");
	return hl_condition_timed_wait(condition,timeout);
}

HL_PRIM void HL_NAME(native_condition_signal)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot signal a null condition variable");
	hl_condition_signal(condition);
}

HL_PRIM void HL_NAME(native_condition_broadcast)( hl_condition *condition ) {
	if( condition == NULL ) hl_error("Cannot broadcast a null condition variable");
	hl_condition_broadcast(condition);
}

HL_PRIM void HL_NAME(native_condition_close)( hl_condition *condition ) {
	if( condition != NULL ) hl_condition_free(condition);
}

typedef struct haxeon_tls {
	void (*finalize)( void * );
	hl_tls *tls;
	bool closed;
} haxeon_tls;

static void haxeon_tls_finalize( void *value ) {
	haxeon_tls *handle = (haxeon_tls *)value;
	if( handle->closed ) return;
	hl_tls_set(handle->tls,NULL);
	hl_tls_free(handle->tls);
	hl_remove_root(&handle->tls);
	handle->tls = NULL;
	handle->closed = true;
}

HL_PRIM haxeon_tls *HL_NAME(native_tls_alloc)( bool gcValue ) {
	haxeon_tls *handle = (haxeon_tls *)hl_gc_alloc_finalizer(sizeof(haxeon_tls));
	memset(handle,0,sizeof(*handle));
	handle->finalize = haxeon_tls_finalize;
	handle->tls = hl_tls_alloc(gcValue);
	if( handle->tls == NULL ) hl_error("HashLink TLS allocation failed");
	hl_add_root(&handle->tls);
	return handle;
}

HL_PRIM vdynamic *HL_NAME(native_tls_get)( haxeon_tls *handle ) {
	if( handle == NULL || handle->closed ) hl_error("Cannot read a closed TLS key");
	return (vdynamic *)hl_tls_get(handle->tls);
}

HL_PRIM void HL_NAME(native_tls_set)( haxeon_tls *handle, vdynamic *value ) {
	if( handle == NULL || handle->closed ) hl_error("Cannot write a closed TLS key");
	hl_tls_set(handle->tls,value);
}

HL_PRIM void HL_NAME(native_tls_clear)( haxeon_tls *handle ) {
	if( handle == NULL || handle->closed ) return;
	hl_tls_set(handle->tls,NULL);
}

HL_PRIM void HL_NAME(native_tls_close)( haxeon_tls *handle ) {
	if( handle == NULL || handle->closed ) return;
	HL_NAME(native_tls_clear)(handle);
	hl_tls_free(handle->tls);
	hl_remove_root(&handle->tls);
	handle->tls = NULL;
	handle->closed = true;
}
